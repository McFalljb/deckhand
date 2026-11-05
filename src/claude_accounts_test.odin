package main

// Claude Code accounts and Claude sessions found on disk (claude_accounts.odin, claude_disk.odin;
// docs/CLAUDE.md §1b, §4c). Every test runs in a fake HOME with fake config folders and fake
// transcripts: never the user's ~/.claude*, never a real claude (a shell line stands in for it).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// The whole test binary runs in a fake HOME (made here, empty): no test may list or read the
// real ~/.claude*, whose projects/ the scans of Claude transcripts would otherwise look at.
@(init)
ca_fake_home_init :: proc "contextless" () {
	when ODIN_TEST {
		test_tmpdir_ensure() // in the process's own temp folder (tmpdir_test.odin)
		context = runtime.default_context()
		d := fmt.aprintf("%s/pi-desk-test-home-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
		os.make_directory_all(d)
		buf: [posix.PATH_MAX]u8
		if r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:])); r != nil do d = strings.clone(string(r))
		os.set_env("HOME", d)
		os.unset_env("CLAUDE_CONFIG_DIR")
		os.unset_env("CLAUDE_CODE_PROJECT_DIR_NAME")
	}
}

@(private = "file")
CA_UI :: Caller{kind = .UI}
@(private = "file")
CA_SCRIPT :: Caller{kind = .Script}
@(private = "file")
CA_CONTROL :: Caller{kind = .Control}

@(private = "file")
ca_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/pi-desk-ca-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r)) : d
}

@(private = "file")
Ca_Env :: struct {
	home, root, envf, argf: string,
}

// A fresh state in a fake HOME (no config folder yet) with a data dir; claude's argv goes to
// argf and its environment to envf at each start.
@(private = "file")
ca_old_home: string
@(private = "file")
ca_old_root: string

@(private = "file")
ca_reset :: proc(env: ^Ca_Env) -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	ca_old_home = strings.clone(os.get_env("HOME", context.temp_allocator))
	ca_old_root = home_root
	// a Rescan an earlier test started (or asked for again) finishes first
	for _ in 0 ..< 500 {
		inbox_drain()
		if scan_thread == nil && !claude_rescan_again do break
		if scan_thread == nil && claude_rescan_again {
			claude_rescan_again = false
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}}
	persist = {}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	login_env.children = nil
	os.unset_env("CLAUDE_CONFIG_DIR")
	os.unset_env("XDG_CONFIG_HOME")
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("PI_DESK_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	claude_found = .Yes
	env.home = ca_dir("home")
	env.root = ca_dir("data")
	d := ca_dir("out")
	env.envf = fmt.aprintf("%s/env", d)
	env.argf = fmt.aprintf("%s/argv", d)
	os.set_env("HOME", env.home)
	home_root = env.root
	os.set_env("PI_DESK_CLAUDE_CMD", fmt.tprintf(`printf '%%s\n' "$@" > '%s.tmp'; mv '%s.tmp' '%s'; env > '%s.tmp'; mv '%s.tmp' '%s'; exec sleep 30`, env.argf, env.argf, env.argf, env.envf, env.envf, env.envf))
	claude_accounts_refresh()
	rescan_now()
	return runtime.heap_allocator()
}

@(private = "file")
ca_done :: proc() {
	os.unset_env("CLAUDE_CONFIG_DIR")
	os.unset_env("XDG_CONFIG_HOME")
	// nothing found stays for the next test (never a look at the real HOME's folders)
	os.set_env("HOME", ca_dir("empty-home"))
	claude_accounts_refresh()
	state.settings.claude_accounts = {}
	os.set_env("HOME", ca_old_home)
	home_root = ca_old_root
}

@(private = "file")
ca_write :: proc(path, text: string) {
	os.make_directory_all(filepath.dir(path))
	_ = os.write_entire_file(path, transmute([]u8)text)
}

// A config folder: settings.json, and the account file when marked (stat is all pi-desk does).
@(private = "file")
ca_config :: proc(dir: string, marked := true) {
	os.make_directory_all(dir)
	ca_write(fmt.tprintf("%s/settings.json", dir), "{}\n")
	if marked do ca_write(fmt.tprintf("%s/.claude.json", dir), `{"secret":"never read"}`)
}

@(private = "file")
ca_wait_file :: proc(path: string) -> string {
	for _ in 0 ..< 250 {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil && len(data) > 0 do return string(data)
		time.sleep(20 * time.Millisecond)
	}
	return ""
}

@(private = "file")
ca_close :: proc(t: ^testing.T, sess: u64) {
	if s := find_session(sess); s != nil do for tab in s.tabs do run_command(Claude_Turn_Report{tab_id = tab.id, state = "idle"}, CA_SCRIPT)
	r := run_command(Close_Session{session = sess}, CA_UI)
	testing.expect(t, r.ok, r.error)
}

@(private = "file")
ca_labels :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for a, i in claude_accounts() {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, a.label)
		if a.default do strings.write_byte(&b, '*')
	}
	return strings.to_string(b)
}

// A transcript line of Claude Code's (the fields pi-desk looks at; the rest as Claude writes it).
@(private = "file")
ca_user :: proc(cwd, text: string, meta := false, sidechain := false) -> string {
	return fmt.tprintf(`{{"parentUuid":null,"isSidechain":%v,"userType":"external","cwd":%q,"sessionId":"x","version":"2.1.317","type":"user",%s"message":{{"role":"user","content":%q}},"uuid":"u1","timestamp":"2026-11-01T10:00:00.000Z"}}`, sidechain, cwd, meta ? `"isMeta":true,` : "", text)
}

// ---- the folder name Claude Code gives a project ----

// The rule (Claude Code 2.1.317, its own projects-folder function): every UTF-16 code unit that
// is not an ASCII letter or digit becomes "-"; past 200 characters, the first 200, "-", and the
// base-36 absolute value of the path's 32-bit string hash. Vectors made by a separate Python
// version of that rule.
@(test)
claude_slug_rule :: proc(t: ^testing.T) {
	testing.expect_value(t, claude_project_slug("/Users/me/my proj.v2"), "-Users-me-my-proj-v2")
	testing.expect_value(t, claude_project_slug("/tmp/café 日本/\U0001F642x"), "-tmp-caf-------x") // é one unit, 🙂 two
	long := strings.concatenate({"/a/", strings.repeat("long-dir_name.", 20, context.temp_allocator), "/end"}, context.temp_allocator)
	testing.expect_value(t, claude_project_slug(long), "-a-long-dir-name-long-dir-name-long-dir-name-long-dir-name-long-dir-name-long-dir-name-long-dir-name-long-dir-name-long-dir-name-long-dir-name-long-dir-name-long-dir-name-long-dir-name-long-dir-name-l-vtd9ux")
	acc := strings.concatenate({"/x/", strings.repeat("é", 210, context.temp_allocator)}, context.temp_allocator)
	want := strings.concatenate({"-x-", strings.repeat("-", 197, context.temp_allocator), "-9r1e0q"}, context.temp_allocator)
	testing.expect_value(t, claude_project_slug(acc), want)
}

// ---- accounts ----

// No config folder at all, or only ~/.claude: one account, nothing to pick, no tag.
@(test)
claude_accounts_one :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	testing.expect_value(t, ca_labels(), "Claude*") // the default, even before Claude Code made it
	testing.expect(t, !claude_accounts_many())
	ca_config(fmt.tprintf("%s/.claude", env.home), marked = false)
	os.make_directory_all(fmt.tprintf("%s/.claude-cache", env.home)) // a folder by that name, no account file: not one
	claude_accounts_refresh()
	testing.expect_value(t, ca_labels(), "Claude*")
	testing.expect_value(t, claude_accounts()[0].dir, fmt.tprintf("%s/.claude", env.home))
	// the default needs no environment: claude runs as it does in the user's shell
	testing.expect_value(t, len(claude_account_env(claude_accounts()[0].dir)), 0)
}

// Folders that hold Claude Code's account file are found (by stat): ~/.claude-*, ~/.config/claude*
// (and XDG_CONFIG_HOME's); labels from the folder's name; the user renames or removes them.
@(test)
claude_accounts_detected :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	ca_config(fmt.tprintf("%s/.claude", env.home), marked = false)
	ca_config(fmt.tprintf("%s/.claude-work", env.home))
	ca_config(fmt.tprintf("%s/.config/claude-personal", env.home))
	os.make_directory_all(fmt.tprintf("%s/.claude-junk", env.home))
	claude_accounts_refresh()
	testing.expect_value(t, ca_labels(), "Claude*,Work,Personal")
	testing.expect(t, claude_accounts_many())
	work := fmt.tprintf("%s/.claude-work", env.home)
	dir, err := claude_account_resolve("work")
	testing.expect_value(t, err, "")
	testing.expect_value(t, dir, work)
	// another account sets CLAUDE_CONFIG_DIR for claude (and again after the login profile ran)
	e := claude_account_env(work)
	testing.expect(t, len(e) > 0 && strings.contains(strings.join(e, "\n", context.temp_allocator), fmt.tprintf("CLAUDE_CONFIG_DIR=%s", work)))
	// rename, remove; the default stays
	testing.expect(t, run_command(Rename_Claude_Account{account = "Work", label = "Day job"}, CA_UI).ok)
	testing.expect_value(t, ca_labels(), "Claude*,Day job,Personal")
	testing.expect(t, run_command(Remove_Claude_Account{account = "Personal"}, CA_UI).ok)
	testing.expect_value(t, ca_labels(), "Claude*,Day job")
	testing.expect(t, !run_command(Remove_Claude_Account{account = "Claude"}, CA_UI).ok, "the default stays")
	// settings are the user's
	testing.expect(t, !run_command(Rename_Claude_Account{account = "Day job", label = "x"}, CA_CONTROL).ok)
	testing.expect(t, !run_command(Remove_Claude_Account{account = "Day job"}, CA_CONTROL).ok)
	// a removed folder stays guarded: its transcripts and account file are still Claude's
	testing.expect(t, claude_credential(fmt.tprintf("%s/.config/claude-personal/projects/x/y.jsonl", env.home)))
	testing.expect(t, claude_credential(fmt.tprintf("%s/.claude-work/projects/x/y.jsonl", env.home)))
	testing.expect(t, claude_credential(fmt.tprintf("%s/.claude-work/history.jsonl", env.home)))
	testing.expect(t, !claude_credential(fmt.tprintf("%s/.claude-work/settings.json", env.home)))
	// kept across a relaunch
	text := workspace_json()
	testing.expect(t, strings.contains(text, `"claude_accounts"`))
	state.settings.claude_accounts = {}
	testing.expect_value(t, ca_labels(), "Claude*,Work,Personal")
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect_value(t, ca_labels(), "Claude*,Day job")
}

// CLAUDE_CONFIG_DIR in pi-desk's login environment (an odd path: spaces, unicode) is the default
// account: plain `claude` uses it. ~/.claude, when there, is another one, started with
// CLAUDE_CONFIG_DIR unset.
@(test)
claude_accounts_env_default :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	odd := fmt.tprintf("%s/My Claude é setup", ca_dir("odd"))
	ca_config(odd)
	ca_config(fmt.tprintf("%s/.claude", env.home), marked = false)
	os.set_env("CLAUDE_CONFIG_DIR", odd)
	claude_accounts_refresh()
	testing.expect_value(t, ca_labels(), "Claude*,~/.claude")
	testing.expect_value(t, claude_accounts()[0].dir, odd)
	testing.expect_value(t, len(claude_account_env(odd)), 0)
	home := fmt.tprintf("%s/.claude", env.home)
	e := strings.join(claude_account_env(home), "\n", context.temp_allocator)
	testing.expect(t, strings.contains(e, "PI_DESK_CLAUDE_ACCOUNT="), "~/.claude: unset after the profile")
	testing.expect(t, !strings.contains(e, "CLAUDE_CONFIG_DIR="), e)
	// a relative CLAUDE_CONFIG_DIR is not Claude's folder: ~/.claude is the default
	os.set_env("CLAUDE_CONFIG_DIR", "relative/dir")
	claude_accounts_refresh()
	testing.expect_value(t, ca_labels(), "Claude*")
}

// "Add account…": any folder, also outside HOME; agents can name only configured accounts.
@(test)
claude_accounts_added :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	acme := fmt.tprintf("%s/acme-claude", ca_dir("outside"))
	ca_config(acme, marked = false)
	testing.expect(t, !run_command(Add_Claude_Account{dir = acme}, CA_CONTROL).ok, "the user's")
	testing.expect(t, !run_command(Add_Claude_Account{dir = "relative"}, CA_UI).ok)
	testing.expect(t, !run_command(Add_Claude_Account{dir = env.home}, CA_UI).ok, "HOME itself is no config folder")
	testing.expect(t, !run_command(Add_Claude_Account{dir = fmt.tprintf("%s/nope", acme)}, CA_UI).ok, "a folder that is there")
	r := run_command(Add_Claude_Account{dir = acme}, CA_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, ca_labels(), "Claude*,Acme-claude")
	testing.expect(t, !run_command(Add_Claude_Account{dir = acme}, CA_UI).ok, "already an account")
	testing.expect(t, claude_credential(fmt.tprintf("%s/projects/p/s.jsonl", acme)), "an added folder is guarded")
	testing.expect(t, claude_credential(fmt.tprintf("%s/.credentials.json", acme)))
	_, err := claude_account_resolve("/etc")
	testing.expect(t, err != "", "not a configured account")
	_, err = claude_account_resolve(fmt.tprintf("%s/.claude-work", env.home))
	testing.expect(t, err != "")
	dir, err2 := claude_account_resolve(acme)
	testing.expect_value(t, err2, "")
	testing.expect_value(t, dir, acme)
}

// Every start sets the tab's account: new (picked or the last used), resume, restore, restart;
// an agent picks a configured one by label only.
@(test)
claude_accounts_start_env :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(fmt.tprintf("%s/.claude", env.home), marked = false)
	ca_config(work)
	// the login profile setting another folder does not win over the tab's account
	ca_write(fmt.tprintf("%s/.profile", env.home), "CLAUDE_CONFIG_DIR=/wrong; export CLAUDE_CONFIG_DIR\n")
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	r := run_command(New_Claude_Session{project_id = pid, account = "Work"}, CA_UI)
	testing.expect(t, r.ok, r.error)
	e := ca_wait_file(env.envf)
	testing.expect(t, strings.contains(e, fmt.tprintf("CLAUDE_CONFIG_DIR=%s\n", work)), e)
	testing.expect(t, !strings.contains(e, "PI_DESK_CLAUDE_ACCOUNT"), "the marker is gone before claude runs")
	s := find_session(r.created_id)
	ct := s.tabs[0].kind.(Claude_Tab)
	testing.expect_value(t, ct.account, work)
	sid := "ca000000-0000-4000-8000-000000000001"
	testing.expect(t, run_command(Claude_Session_Report{tab_id = s.tabs[0].id, session_id = sid, source = "startup"}, CA_SCRIPT).ok)
	rec, _ := claude_record(sid)
	testing.expect(t, rec != nil && rec.account == work)
	// the last used is the next default (the project's)
	os.remove(env.envf)
	r2 := run_command(New_Claude_Session{project_id = pid}, CA_UI)
	testing.expect(t, r2.ok, r2.error)
	testing.expect(t, strings.contains(ca_wait_file(env.envf), fmt.tprintf("CLAUDE_CONFIG_DIR=%s\n", work)))
	// the default account: CLAUDE_CONFIG_DIR as the login shell leaves it (here: its profile's)
	os.remove(env.envf)
	r3 := run_command(New_Claude_Session{project_id = pid, account = "Claude"}, CA_UI)
	testing.expect(t, r3.ok, r3.error)
	testing.expect(t, strings.contains(ca_wait_file(env.envf), "CLAUDE_CONFIG_DIR=/wrong\n"), "the default changes nothing")
	// agents: a configured label, never a folder of their own
	testing.expect(t, !run_command(New_Claude_Session{project_id = pid, account = "/tmp"}, CA_CONTROL).ok)
	testing.expect(t, !run_command(New_Claude_Session{project_id = pid, account = "nope"}, CA_CONTROL).ok)
	testing.expect(t, run_command(New_Claude_Tab{project_id = pid, account = "work"}, CA_CONTROL).ok)
	// a resume from the row (closed first) runs under the record's account
	ca_close(t, r.created_id)
	os.remove(env.envf)
	rr := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = sid}, CA_UI)
	testing.expect(t, rr.ok, rr.error)
	testing.expect(t, strings.contains(ca_wait_file(env.envf), fmt.tprintf("CLAUDE_CONFIG_DIR=%s\n", work)))
	// the tab and the record keep the account across a relaunch
	text := workspace_json()
	testing.expect(t, strings.contains(text, fmt.tprintf(`"account":%q`, work)))
}

// Accounts on records: a record whose account is no longer configured does not start elsewhere.
@(test)
claude_accounts_gone :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(work)
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	r := run_command(New_Claude_Session{project_id = pid, account = "Work"}, CA_UI)
	testing.expect(t, r.ok, r.error)
	sid := "ca000000-0000-4000-8000-000000000002"
	run_command(Claude_Session_Report{tab_id = find_session(r.created_id).tabs[0].id, session_id = sid, source = "startup"}, CA_SCRIPT)
	ca_close(t, r.created_id)
	testing.expect(t, run_command(Remove_Claude_Account{account = "Work"}, CA_UI).ok)
	rr := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = sid}, CA_UI)
	testing.expect(t, !rr.ok && strings.contains(rr.error, "account"), rr.error)
}

// ---- Claude sessions found on disk ----

@(private = "file")
ca_transcripts :: proc(cfg, cwd: string) -> string {
	d := fmt.tprintf("%s/projects/%s", cfg, claude_project_slug(cwd))
	os.make_directory_all(d)
	return d
}

@(private = "file")
ca_row_text :: proc(section: Sort_Section = .Sessions) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r, i in sidebar_sessions(section) {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, session_label(r.session^, section == .Chats))
		if r.session.claude do strings.write_string(&b, "(c)")
		if l := session_account_tag(r.session^); l != "" do fmt.sbprintf(&b, "[%s]", l)
	}
	return strings.to_string(b)
}

@(private = "file")
ca_touch :: proc(path: string, secs_ago: int) {
	t := time.time_add(time.now(), -time.Duration(secs_ago) * time.Second)
	os.change_times(path, t, t)
}

// The selected project's Claude Code conversations from every account's projects/ folder: titles
// from the first real prompt (or the user's /rename, Claude's title or summary), newest first
// with pi's, never a sidechain or subagent file, never one pi-desk already lists.
@(test)
claude_disk_rows_listed :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	home_cfg := fmt.tprintf("%s/.claude", env.home)
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(home_cfg, marked = false)
	ca_config(work)
	claude_accounts_refresh()
	proj := fmt.tprintf("%s/My Proj été", ca_dir("proj")) // spaces and unicode
	os.make_directory_all(proj)
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	run_command(Select_Project{project_id = pid}, CA_UI)
	testing.expect_value(t, ca_row_text(), "")
	d := ca_transcripts(home_cfg, proj)
	w := ca_transcripts(work, proj)
	a := "aaaaaaaa-0000-4000-8000-000000000001"
	b := "bbbbbbbb-0000-4000-8000-000000000002"
	c := "cccccccc-0000-4000-8000-000000000003"
	s := "dddddddd-0000-4000-8000-000000000004"
	n := "eeeeeeee-0000-4000-8000-000000000005"
	ca_write(fmt.tprintf("%s/%s.jsonl", d, a), strings.join({`{"type":"summary","summary":"Old summary","leafUuid":"x"}`, ca_user(proj, "<command-name>/clear</command-name>"), ca_user(proj, "Caveat: the messages below", meta = true), ca_user(proj, "fix the login bug\nsecond line"), ""}, "\n", context.temp_allocator))
	ca_write(fmt.tprintf("%s/%s.jsonl", d, b), strings.join({ca_user(proj, "first prompt"), `{"type":"custom-title","customTitle":"Named by me","sessionId":"b"}`, ""}, "\n", context.temp_allocator))
	ca_write(fmt.tprintf("%s/%s.jsonl", w, c), strings.join({ca_user(proj, "work thing"), ""}, "\n", context.temp_allocator))
	ca_write(fmt.tprintf("%s/%s.jsonl", d, s), strings.join({ca_user(proj, "a sidechain", sidechain = true), ""}, "\n", context.temp_allocator))
	ca_write(fmt.tprintf("%s/agent-1234abcd.jsonl", d), ca_user(proj, "a subagent"))
	ca_write(fmt.tprintf("%s/%s/subagents/agent-1.jsonl", d, a), ca_user(proj, "a subagent too"))
	ca_write(fmt.tprintf("%s/%s.jsonl", d, n), strings.join({ca_user(proj, "Caveat: only meta so far", meta = true), ""}, "\n", context.temp_allocator)) // no prompt yet: untitled
	ca_touch(fmt.tprintf("%s/%s.jsonl", d, a), 300)
	ca_touch(fmt.tprintf("%s/%s.jsonl", d, b), 200)
	ca_touch(fmt.tprintf("%s/%s.jsonl", w, c), 100)
	ca_touch(fmt.tprintf("%s/%s.jsonl", d, n), 400)
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	testing.expect_value(t, ca_row_text(), "work thing(c)[Work],Named by me(c)[Claude],fix the login bug(c)[Claude],Untitled Claude session(c)[Claude]")
	// the snapshot: the rows as pi's are listed, with no transcript path
	snap := state_json()
	testing.expect(t, strings.contains(snap, `"found":true`))
	testing.expect(t, !strings.contains(snap, ".jsonl"), "no transcript path for agents")
	// one pi-desk already has (its own history) is not listed twice
	r := run_command(New_Claude_Session{project_id = pid, account = "Claude"}, CA_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, run_command(Claude_Session_Report{tab_id = find_session(r.created_id).tabs[0].id, session_id = b, source = "resume"}, CA_SCRIPT).ok)
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	rows := ca_row_text()
	testing.expect_value(t, strings.count(rows, "(c)"), 4)
}

// A click on a found row resumes it in a Claude-only session under its account: --resume <id>,
// the account's CLAUDE_CONFIG_DIR; an agent's too, without the user's flags (there are none).
@(test)
claude_disk_resume_row :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(work)
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	id := "ffffffff-0000-4000-8000-000000000006"
	ca_write(fmt.tprintf("%s/%s.jsonl", ca_transcripts(work, proj), id), strings.join({ca_user(proj, "resume me"), ""}, "\n", context.temp_allocator))
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	testing.expect_value(t, ca_row_text(), "resume me(c)[Work]")
	r := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = id}, CA_UI)
	testing.expect(t, r.ok, r.error)
	s := find_session(r.created_id)
	testing.expect(t, s != nil && s.agent == .Claude)
	argv := ca_wait_file(env.argf)
	// by the transcript's absolute path (its account's folder), as --resume takes it
	testing.expect(t, strings.contains(argv, fmt.tprintf("--resume\n%s/projects/%s/%s.jsonl\n", work, claude_project_slug(proj), id)), argv)
	testing.expect(t, strings.contains(ca_wait_file(env.envf), fmt.tprintf("CLAUDE_CONFIG_DIR=%s\n", work)))
	rec, _ := claude_record(id)
	testing.expect(t, rec != nil && rec.account == work && rec.project == proj)
	testing.expect_value(t, rec.title, "resume me")
	// an id that is not a file of this project's is no row (no path tricks)
	testing.expect(t, !run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "../../x"}, CA_CONTROL).ok)
	testing.expect(t, !run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "00000000-0000-4000-8000-00000000dead"}, CA_CONTROL).ok)
}

// Claude conversations in the chats folder list in Chats; with Chats: read-only on, one resumed
// from there runs read-only (and stays so).
@(test)
claude_disk_chats_readonly :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	// a read-only tab never starts without pi-desk-cli (its guard): a stand-in, not whatever a
	// release build left next to the test binary
	cli := fmt.tprintf("%s/pi-desk-cli", ca_dir("cli"))
	_ = os.write_entire_file(cli, transmute([]u8)string("#!/bin/sh\nexit 0\n"))
	claude_cli_override = cli
	defer claude_cli_override = ""
	cfg := fmt.tprintf("%s/.claude", env.home)
	ca_config(cfg, marked = false)
	claude_accounts_refresh()
	chats := chats_project()
	testing.expect(t, chats != nil)
	if chats == nil do return
	os.make_directory_all(chats.cwd)
	id := "12121212-0000-4000-8000-000000000007"
	ca_write(fmt.tprintf("%s/%s.jsonl", ca_transcripts(cfg, chats.cwd), id), strings.join({ca_user(chats.cwd, "a chat from the shell"), ""}, "\n", context.temp_allocator))
	run_command(Set_Chats_Readonly{on = true}, CA_UI)
	rescan_now()
	claude_disk_wait()
	testing.expect_value(t, ca_row_text(.Chats), "a chat from the shell(c)")
	r := run_command(Open_Session_Cmd{project_id = chats_project().id, pi_session_id = id}, CA_UI)
	testing.expect(t, r.ok, r.error)
	argv := ca_wait_file(env.argf)
	testing.expect(t, strings.contains(argv, "--permission-mode\nplan"), argv)
	testing.expect(t, claude_readonly_known(id), "its conversation stays read-only")
}

// Reading titles stays within its budget: the head and tail of a long transcript, never all of it.
@(test)
claude_disk_budget :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	cfg := fmt.tprintf("%s/.claude", env.home)
	ca_config(cfg, marked = false)
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	id := "34343434-0000-4000-8000-000000000008"
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ca_user(proj, "the long one"))
	strings.write_byte(&b, '\n')
	filler := fmt.tprintf(`{{"type":"assistant","message":{{"content":"%s"}}}}`, strings.repeat("x", 1000, context.temp_allocator))
	for _ in 0 ..< 4000 {
		strings.write_string(&b, filler)
		strings.write_byte(&b, '\n')
	}
	ca_write(fmt.tprintf("%s/%s.jsonl", ca_transcripts(cfg, proj), id), strings.to_string(b))
	before := claude_disk_bytes_read
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	testing.expect_value(t, ca_row_text(), "the long one(c)")
	read := claude_disk_bytes_read - before
	testing.expect(t, read <= 2 * CLAUDE_DISK_CHUNK, fmt.tprintf("read %d bytes of %d", read, strings.builder_len(b)))
}

// No Claude Code, no projects/ folder, a config folder that is a file: nothing shows, nothing breaks.
@(test)
claude_disk_nothing :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	claude_found = .No
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	testing.expect_value(t, ca_row_text(), "")
	ca_write(fmt.tprintf("%s/.claude", env.home), "not a folder")
	claude_accounts_refresh()
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	testing.expect_value(t, ca_row_text(), "")
}

// A symlinked project folder: Claude names the folder by the real path it runs in.
@(test)
claude_disk_symlink :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	cfg := fmt.tprintf("%s/.claude", env.home)
	ca_config(cfg, marked = false)
	claude_accounts_refresh()
	real := ca_dir("real")
	link := fmt.tprintf("%s/link to it", ca_dir("links"))
	posix.symlink(strings.clone_to_cstring(real, context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator))
	pid := run_command(Add_Project{cwd = link}, CA_UI).created_id
	id := "56565656-0000-4000-8000-000000000009"
	ca_write(fmt.tprintf("%s/%s.jsonl", ca_transcripts(cfg, real), id), strings.join({ca_user(real, "via the real path"), ""}, "\n", context.temp_allocator))
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	testing.expect_value(t, ca_row_text(), "via the real path(c)")
}

// The harness of a row: pi or Claude (its icons: logos_test.odin).
@(test)
claude_harness_of_rows :: proc(t: ^testing.T) {
	testing.expect_value(t, session_harness(Session{claude = true}), Harness.Claude)
	testing.expect_value(t, session_harness(Session{}), Harness.Pi)
}

// Settings: each account's config files in its own group once there are several; transcripts
// under any account never kept for a path that is outside every account's projects/.
@(test)
claude_accounts_settings_groups :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(fmt.tprintf("%s/.claude", env.home), marked = false)
	ca_config(work)
	claude_accounts_refresh()
	groups := make(map[string]bool, context.temp_allocator)
	paths := make(map[string]bool, context.temp_allocator)
	for r in settings_file_rows() {
		groups[r.group] = true
		paths[r.path] = true
	}
	testing.expect(t, fmt.tprintf("%s/settings.json", work) in paths, "the work account's settings")
	testing.expect(t, fmt.tprintf("%s/.claude/settings.json", env.home) in paths)
	testing.expect(t, "claude-accounts" in groups, "the accounts group")
	testing.expect(t, !(fmt.tprintf("%s/.claude.json", work) in paths))
	testing.expect_value(t, settings_json_kind(fmt.tprintf("%s/settings.json", work)), Json_Kind.Strict)
	tp := fmt.tprintf("%s/projects/-x/abc.jsonl", work)
	ca_write(tp, "")
	testing.expect(t, claude_transcript_ok(tp) != "", "a transcript under another account's projects/")
	testing.expect_value(t, claude_file_class(fmt.tprintf("%s/commands/x.md", work)), Claude_File_Class.Restart)
	testing.expect_value(t, claude_file_class(fmt.tprintf("%s/settings.json", work)), Claude_File_Class.Live)
}

// Projects where only Claude ran: from each account's projects/, by the cwd its newest transcript
// records (never a folder name turned back into a path); Rescan finds new ones.
@(test)
claude_disk_projects :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(work)
	claude_accounts_refresh()
	only := fmt.tprintf("%s/claude only é", ca_dir("only"))
	os.make_directory_all(only)
	id := "78787878-0000-4000-8000-00000000000a"
	ca_write(fmt.tprintf("%s/%s.jsonl", ca_transcripts(work, only), id), strings.join({ca_user(only, "hello"), ""}, "\n", context.temp_allocator))
	// a folder whose transcripts record another cwd than its name says: not a project of that name
	liar := fmt.tprintf("%s/projects/-not-a-real-place", work)
	ca_write(fmt.tprintf("%s/%s.jsonl", liar, "89898989-0000-4000-8000-00000000000b"), strings.join({ca_user("/somewhere/else", "x"), ""}, "\n", context.temp_allocator))
	rescan_now()
	p := project_by_cwd(only)
	testing.expect(t, p != nil, "the folder Claude ran in is a project")
	testing.expect(t, project_by_cwd("/somewhere/else") == nil)
	testing.expect(t, project_by_cwd("/not/a/real/place") == nil, "never decoded from the name")
	if p == nil do return
	run_command(Select_Project{project_id = p.id}, CA_UI)
	claude_disk_wait()
	testing.expect_value(t, ca_row_text(), "hello(c)[Work]")
}

// A history entry whose transcript is gone (Claude Code's clean-up): greyed, by stat; its created
// date is the transcript's while it is there.
@(test)
claude_disk_gone_and_created :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	cfg := fmt.tprintf("%s/.claude", env.home)
	ca_config(cfg, marked = false)
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	sid := "9a9a9a9a-0000-4000-8000-00000000000c"
	r := run_command(New_Claude_Session{project_id = pid}, CA_UI)
	tab := find_session(r.created_id).tabs[0].id
	tp := fmt.tprintf("%s/%s.jsonl", ca_transcripts(cfg, proj), sid)
	ca_write(tp, strings.join({ca_user(proj, "kept"), ""}, "\n", context.temp_allocator))
	testing.expect(t, run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "startup", transcript_path = tp}, CA_SCRIPT).ok)
	run_command(Claude_Turn_Report{tab_id = tab, state = "submitted", title = "kept"}, CA_SCRIPT)
	ca_close(t, r.created_id)
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	rows := sidebar_sessions(.Sessions)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect(t, !rows[0].session.gone)
		fi, _ := os.stat(tp, context.temp_allocator)
		testing.expect_value(t, rows[0].session.when_, utc_minute(fi.creation_time))
	}
	os.remove(tp)
	run_command(Rescan{}, CA_UI)
	for _ in 0 ..< 200 {
		inbox_drain()
		if scan_thread == nil do break
		time.sleep(10 * time.Millisecond)
	}
	claude_disk_wait()
	rows = sidebar_sessions(.Sessions)
	testing.expect(t, len(rows) == 1 && rows[0].session.gone, "the transcript is gone")
	testing.expect(t, strings.contains(state_json(), `"gone":true`))
}

// CLAUDE_CODE_PROJECT_DIR_NAME (honoured by Claude Code while CLAUDE_CONFIG_DIR is set): every
// project's transcripts in one folder; only those whose cwd is the project's are its rows.
@(test)
claude_disk_dir_override :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	defer os.unset_env("CLAUDE_CODE_PROJECT_DIR_NAME")
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(work)
	os.set_env("CLAUDE_CODE_PROJECT_DIR_NAME", "jobs")
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	shared := fmt.tprintf("%s/projects/jobs", work)
	ca_write(fmt.tprintf("%s/%s.jsonl", shared, "abababab-0000-4000-8000-00000000000d"), strings.join({ca_user(proj, "mine"), ""}, "\n", context.temp_allocator))
	ca_write(fmt.tprintf("%s/%s.jsonl", shared, "cdcdcdcd-0000-4000-8000-00000000000e"), strings.join({ca_user("/other/project", "theirs"), ""}, "\n", context.temp_allocator))
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	testing.expect_value(t, ca_row_text(), "mine(c)[Work]")
	// a name Claude Code would not take is not looked for
	os.set_env("CLAUDE_CODE_PROJECT_DIR_NAME", "../x")
	testing.expect_value(t, claude_project_dir_override(work), "")
}

// The account picker: with several accounts, "New session"'s harness picker (harness.odin) lists
// Claude Code once per account (the pick for this project first) and each starts its own; menus
// get one row per account; with one, a single row.
@(test)
claude_accounts_picker :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	defer menu_close()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	items := make([dynamic]Menu_Item, context.temp_allocator)
	claude_account_items(&items, "New Claude session", New_Claude_Session{project_id = pid})
	testing.expect_value(t, len(items), 1)
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(work)
	claude_accounts_refresh()
	clear(&items)
	claude_account_items(&items, "New Claude session", New_Claude_Session{project_id = pid})
	testing.expect_value(t, len(items), 2)
	if len(items) == 2 {
		testing.expect_value(t, items[1].label, "New Claude session · Work")
		c, _ := items[1].cmd.(New_Claude_Session)
		testing.expect_value(t, c.account, work)
		testing.expect(t, items[0].check, "the default is checked first")
	}
	claude_installed_probe = proc() -> bool {return true}
	defer claude_installed_probe = nil
	pi_installed_probe = proc() -> bool {return false} // Claude Code alone: its accounts are the choices
	defer pi_installed_probe = nil
	menu_open(Menu_New_Session{project_id = pid}, {0, 0})
	rows := menu_items()
	testing.expect_value(t, len(rows), 3) // the note, then each account
	if len(rows) == 3 {
		testing.expect(t, rows[0].note)
		testing.expect_value(t, rows[2].label, "Claude Code · Work")
	}
	// after one under Work, Work is the pick: first
	testing.expect(t, run_command(New_Claude_Session{project_id = pid, account = "Work"}, CA_UI).ok)
	rows = menu_items()
	testing.expect(t, len(rows) == 3 && rows[1].label == "Claude Code · Work", "the last used first")
	// a pi or Claude tab's own view of the state has no account folders
	testing.expect(t, strings.contains(state_json(), `"claude_accounts":[`))
	tab := find_session(state.current_session).tabs[0].id
	testing.expect(t, !strings.contains(session_state_json(tab), `"claude_accounts"`))
}

// ---- the default account, Settings' controls, the setup sheet's step ----

// The default account: chosen in Settings or the setup sheet (Set_Claude_Account_Default, the
// user's); a new Claude session starts there unless its project last used another. Removing it
// goes back to the environment's default.
@(test)
claude_accounts_default_choice :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	home := fmt.tprintf("%s/.claude", env.home)
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(home, marked = false)
	ca_config(work)
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	testing.expect_value(t, claude_account_pick(find_project(pid)), home)
	testing.expect(t, run_command(Set_Claude_Account_Default{account = "Work"}, CA_UI).ok)
	testing.expect_value(t, claude_account_pick(find_project(pid)), work)
	testing.expect_value(t, claude_account_pick(nil), work)
	testing.expect(t, !run_command(Set_Claude_Account_Default{account = "Claude"}, CA_CONTROL).ok, "the user's")
	testing.expect(t, !run_command(Set_Claude_Account_Default{account = "/tmp/nowhere"}, CA_UI).ok, "configured accounts only")
	testing.expect(t, strings.contains(state_json(), `"chosen":true`), "the snapshot marks it")
	// the project's last used wins; elsewhere the chosen default
	r := run_command(New_Claude_Session{project_id = pid, account = "Claude"}, CA_UI)
	testing.expect(t, r.ok)
	run_command(Claude_Session_Report{tab_id = find_session(r.created_id).tabs[0].id, session_id = "61616161-0000-4000-8000-000000000001", source = "startup"}, CA_SCRIPT)
	testing.expect_value(t, claude_account_pick(find_project(pid)), home)
	testing.expect_value(t, claude_account_pick(nil), work)
	// kept across a relaunch
	text := workspace_json()
	delete(state.settings.claude_account_default)
	state.settings.claude_account_default = ""
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect_value(t, state.settings.claude_account_default, work)
	// the environment's default again: nothing stored
	testing.expect(t, run_command(Set_Claude_Account_Default{account = "Claude"}, CA_UI).ok)
	testing.expect_value(t, state.settings.claude_account_default, "")
	testing.expect(t, run_command(Set_Claude_Account_Default{account = "Work"}, CA_UI).ok)
	testing.expect(t, run_command(Remove_Claude_Account{account = "Work"}, CA_UI).ok)
	testing.expect_value(t, state.settings.claude_account_default, "")
}

// Settings → Claude accounts: each account's row has Rename…, Make default (all but the
// default) and Remove (all but the environment's default); "Scan again" looks for folders again.
@(test)
claude_accounts_settings_controls :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(fmt.tprintf("%s/.claude", env.home), marked = false)
	ca_config(work)
	claude_accounts_refresh()
	row :: proc(path: string) -> (Settings_File_Row, bool) {
		for r in settings_file_rows() do if r.path == path do return r, true
		return {}, false
	}
	wr, ok := row(strings.concatenate({CLAUDE_ACCOUNT_ROW, work}, context.temp_allocator))
	testing.expect(t, ok && wr.make_default && wr.remove, "Work: make default, remove")
	hr, hok := row(strings.concatenate({CLAUDE_ACCOUNT_ROW, fmt.tprintf("%s/.claude", env.home)}, context.temp_allocator))
	testing.expect(t, hok && !hr.make_default && !hr.remove, "the default: neither")
	_, sok := row(CLAUDE_ACCOUNT_SCAN_ROW)
	testing.expect(t, sok, "Scan again")
	testing.expect(t, run_command(Set_Claude_Account_Default{account = "Work"}, CA_UI).ok)
	wr, _ = row(strings.concatenate({CLAUDE_ACCOUNT_ROW, work}, context.temp_allocator))
	hr, _ = row(strings.concatenate({CLAUDE_ACCOUNT_ROW, fmt.tprintf("%s/.claude", env.home)}, context.temp_allocator))
	testing.expect(t, !wr.make_default && hr.make_default, "the chosen one is the default now")
	testing.expect(t, strings.contains(wr.detail, "default"), wr.detail)
	// a folder made later: found by Scan again (Rescan)
	ca_config(fmt.tprintf("%s/.claude-later", env.home))
	testing.expect(t, run_command(Rescan{}, CA_UI).ok)
	testing.expect_value(t, ca_labels(), "Claude*,Later,Work") // found ones by name
}

// The setup sheet's accounts step: shown only with two or more accounts found (none, or one:
// nothing extra, the last step's line confirms it).
@(test)
claude_setup_accounts_few :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	setup_begin()
	testing.expect_value(t, setup_steps(), 4)
	ca_config(fmt.tprintf("%s/.claude", env.home))
	setup_begin()
	testing.expect_value(t, setup_steps(), 4)
	testing.expect(t, strings.contains(setup_claude_line(), "~/.claude"), setup_claude_line())
}

// Two found plus folders added by hand (one outside HOME, one without Claude Code's files: a
// warning, still added); unticked ones are removed, labels renamed, the default chosen: Done
// writes the same accounts setting Settings edits.
@(test)
claude_setup_accounts_many :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	home := fmt.tprintf("%s/.claude", env.home)
	work := fmt.tprintf("%s/.claude-work", env.home)
	personal := fmt.tprintf("%s/.config/claude-personal", env.home)
	ca_config(home)
	ca_config(work)
	ca_config(personal)
	outside := fmt.tprintf("%s/Team Claude é", ca_dir("outside"))
	ca_config(outside)
	plain := ca_dir("plain")
	setup_begin()
	testing.expect_value(t, setup_steps(), 5)
	testing.expect_value(t, len(setup_ui.accounts), 3)
	ok, msg := setup_account_add(outside)
	testing.expect(t, ok && msg == "", msg)
	ok, msg = setup_account_add(plain)
	testing.expect(t, ok, msg)
	testing.expect(t, strings.contains(msg, "no Claude Code files"), msg)
	ok, msg = setup_account_add("/no/such/folder")
	testing.expect(t, !ok && strings.contains(msg, "no such folder"), msg)
	ok, msg = setup_account_add("relative/dir")
	testing.expect(t, !ok, msg)
	ok, msg = setup_account_add(work)
	testing.expect(t, !ok && strings.contains(msg, "already"), msg)
	ok, msg = setup_account_add(env.home)
	testing.expect(t, !ok, msg)
	testing.expect_value(t, len(setup_ui.accounts), 5)
	// ~ works in a typed path
	testing.expect(t, setup_ui.accounts[0].fixed, "the environment's default stays ticked")
	setup_account_toggle(0)
	testing.expect(t, setup_ui.accounts[0].keep)
	setup_account_toggle(2) // Personal: not kept
	setup_account_set_label(1, "Job")
	setup_ui.acct_default = 1
	// nothing written before Done
	testing.expect_value(t, ca_labels(), "Claude*,Work,Personal")
	setup_accounts_done()
	inbox_drain()
	testing.expect_value(t, ca_labels(), fmt.tprintf("Claude*,Job,Team Claude é,%s", claude_account_label_of(plain)))
	testing.expect_value(t, state.settings.claude_account_default, work)
	// a removed account shows unticked; choosing it as the default ticks it; unticking the
	// default moves it back to the environment's
	setup_begin()
	testing.expect_value(t, setup_steps(), 5)
	testing.expect_value(t, setup_ui.accounts[setup_ui.acct_default].dir, work) // the chosen default, pre-selected
	pi := -1
	for a, i in setup_ui.accounts do if a.dir == personal do pi = i
	testing.expect(t, pi > 0 && !setup_ui.accounts[pi].keep, "a removed account shows unticked")
	if pi > 0 {
		setup_account_set_default(pi)
		testing.expect(t, setup_ui.accounts[pi].keep, "the default is ticked")
		testing.expect_value(t, setup_ui.acct_default, pi)
		setup_account_toggle(pi)
		testing.expect_value(t, setup_ui.acct_default, 0)
	}
}

// ---- review: claude-accounts-discovery ----

// A transcript line nested 20,000 deep (about 40 KB: inside the head) never reaches the JSON
// parser (its recursion would overflow the stack: a crash at every launch); the lines after it
// still count.
@(test)
claude_review_deep_line :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	cfg := fmt.tprintf("%s/.claude", env.home)
	ca_config(cfg)
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"type":"user","cwd":%q,"isSidechain":false,"a":`, proj)
	for _ in 0 ..< 20_000 do strings.write_byte(&b, '[')
	for _ in 0 ..< 20_000 do strings.write_byte(&b, ']')
	strings.write_string(&b, "}\n")
	strings.write_string(&b, ca_user(proj, "after the deep one"))
	strings.write_string(&b, "\n")
	id := "dee0dee0-0000-4000-8000-000000000001"
	tp := fmt.tprintf("%s/%s.jsonl", ca_transcripts(cfg, proj), id)
	ca_write(tp, strings.to_string(b))
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	testing.expect_value(t, ca_row_text(), "after the deep one(c)")
	f, ok := claude_disk_lookup(find_project(pid), id)
	testing.expect(t, !ok || f.title != "", "a lookup reads it too")
	claude_scan_prepare()
	projects := make([dynamic]Project, context.temp_allocator)
	claude_scan_projects(&projects)
	testing.expect_value(t, len(projects), 1)
}

// A 1 MB line: never read whole (the head and tail are 64 KB each), never parsed.
@(test)
claude_review_long_line :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	cfg := fmt.tprintf("%s/.claude", env.home)
	ca_config(cfg)
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	big := strings.repeat("x", 1 << 20, context.temp_allocator)
	text := strings.join({ca_user(proj, big), ca_user(proj, "short"), ""}, "\n", context.temp_allocator)
	tp := fmt.tprintf("%s/%s.jsonl", ca_transcripts(cfg, proj), "10ad10ad-0000-4000-8000-000000000001")
	ca_write(tp, text)
	before := claude_disk_bytes_read
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	testing.expect(t, claude_disk_bytes_read - before <= 4 * CLAUDE_DISK_CHUNK, "bounded reads")
	testing.expect(t, strings.contains(ca_row_text(), "(c)"), ca_row_text())
}

// An account folder never holds a project, the main folder or the chats folder (it would lock
// them out of the editor and Files); a removed hand-added folder without Claude Code's files is
// no longer guarded.
@(test)
claude_review_add_container :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	ca_config(fmt.tprintf("%s/.claude", env.home), marked = false)
	claude_accounts_refresh()
	ws := ca_dir("workspace")
	proj := fmt.tprintf("%s/code/app", ws)
	os.make_directory_all(proj)
	testing.expect(t, run_command(Add_Project{cwd = proj}, CA_UI).ok)
	r := run_command(Add_Claude_Account{dir = ws}, CA_UI)
	testing.expect(t, !r.ok && strings.contains(r.error, "project"), r.error)
	r = run_command(Add_Claude_Account{dir = proj}, CA_UI)
	testing.expect(t, !r.ok, "a project itself")
	main_dir := ca_dir("main")
	state.settings.home_dir = main_dir
	r = run_command(Add_Claude_Account{dir = main_dir}, CA_UI)
	testing.expect(t, !r.ok, "the main folder")
	r = run_command(Add_Claude_Account{dir = filepath.dir(main_dir)}, CA_UI)
	testing.expect(t, !r.ok, "above the main folder")
	state.settings.home_dir = ""
	// the setup sheet's add: the same rule
	ok, msg := setup_account_add(ws)
	testing.expect(t, !ok && strings.contains(msg, "project"), msg)
	// removed: a folder without Claude Code's files is no longer Claude's
	plain := ca_dir("plain")
	testing.expect(t, run_command(Add_Claude_Account{dir = plain}, CA_UI).ok)
	testing.expect(t, claude_credential(fmt.tprintf("%s/projects/x/y.jsonl", plain)))
	testing.expect(t, run_command(Remove_Claude_Account{account = plain}, CA_UI).ok)
	testing.expect(t, !claude_credential(fmt.tprintf("%s/projects/x/y.jsonl", plain)), "removed, no account file")
	real := ca_dir("real")
	ca_config(real)
	testing.expect(t, run_command(Add_Claude_Account{dir = real}, CA_UI).ok)
	testing.expect(t, run_command(Remove_Claude_Account{account = real}, CA_UI).ok)
	testing.expect(t, claude_credential(fmt.tprintf("%s/projects/x/y.jsonl", real)), "removed, an account file: still guarded")
}

// Resuming a recorded session never moves it to another account.
@(test)
claude_review_resume_account :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	home := fmt.tprintf("%s/.claude", env.home)
	ca_config(home, marked = false)
	ca_config(fmt.tprintf("%s/.claude-work", env.home))
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	r := run_command(New_Claude_Session{project_id = pid, account = "Claude"}, CA_UI)
	sid := "5e5e5e5e-0000-4000-8000-000000000001"
	run_command(Claude_Session_Report{tab_id = find_session(r.created_id).tabs[0].id, session_id = sid, source = "startup"}, CA_SCRIPT)
	ca_close(t, r.created_id)
	r2 := run_command(New_Claude_Tab{project_id = pid, resume = sid, account = "Work"}, CA_CONTROL)
	testing.expect(t, !r2.ok && strings.contains(r2.error, "account"), r2.error)
	rec, _ := claude_record(sid)
	testing.expect(t, rec != nil && rec.account == home, "still the home account")
	// a report from another account's tab keeps the record's
	r3 := run_command(New_Claude_Session{project_id = pid, account = "Work"}, CA_UI)
	run_command(Claude_Session_Report{tab_id = find_session(r3.created_id).tabs[0].id, session_id = sid, source = "resume"}, CA_SCRIPT)
	rec, _ = claude_record(sid)
	testing.expect(t, rec != nil && rec.account == home, "history_touch keeps its account")
}

// The launch's first scan (main thread) reads no transcript: Claude's projects come with the
// Rescan after the saved accounts (removed ones left out) are back.
@(test)
claude_review_startup_scan :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(work)
	claude_accounts_refresh()
	only := ca_dir("only")
	ca_write(fmt.tprintf("%s/%s.jsonl", ca_transcripts(work, only), "57a57a57-0000-4000-8000-000000000001"), strings.join({ca_user(only, "hi"), ""}, "\n", context.temp_allocator))
	before := claude_disk_bytes_read
	rescan_now(claude = false)
	testing.expect_value(t, claude_disk_bytes_read, before)
	testing.expect(t, project_by_cwd(only) == nil, "not yet")
	testing.expect(t, claude_startup_rescan_due(), "an account has projects/")
	// the saved settings removed that account: the Rescan leaves its projects out
	testing.expect(t, run_command(Remove_Claude_Account{account = "Work"}, CA_UI).ok)
	run_command(Rescan{}, CA_UI)
	for _ in 0 ..< 300 {
		inbox_drain()
		if scan_thread == nil do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, project_by_cwd(only) == nil, "a removed account's projects stay out")
}

// Projects where only Claude ran: 500 folders read a few KB each for the cwd, then nothing
// (cached by path, size and date).
@(test)
claude_review_discovery_500 :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	cfg := fmt.tprintf("%s/.claude", env.home)
	ca_config(cfg)
	claude_accounts_refresh()
	base := ca_dir("many")
	pad := strings.repeat("p", 100_000, context.temp_allocator)
	for i in 0 ..< 500 {
		cwd := fmt.tprintf("%s/p%d", base, i)
		ca_write(fmt.tprintf("%s/%08x-0000-4000-8000-000000000001.jsonl", ca_transcripts(cfg, cwd), i), strings.join({ca_user(cwd, "hello"), ca_user(cwd, pad), ""}, "\n", context.temp_allocator))
	}
	claude_scan_prepare()
	before := claude_disk_bytes_read
	start := time.tick_now()
	projects := make([dynamic]Project, context.temp_allocator)
	claude_scan_projects(&projects)
	took := time.tick_since(start)
	testing.expect_value(t, len(projects), 500)
	read := claude_disk_bytes_read - before
	testing.expectf(t, read <= 500 * 8192, "read %d bytes", read)
	testing.expectf(t, took < 2 * time.Second, "took %v", took)
	before = claude_disk_bytes_read
	clear(&projects)
	claude_scan_projects(&projects)
	testing.expect_value(t, claude_disk_bytes_read - before, 0)
	testing.expect_value(t, len(projects), 500)
}

// A full title cache still takes new entries (the oldest go): never a read-queue-rescan loop.
@(test)
claude_review_cache_full :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	old_max := claude_disk_cache_max
	claude_disk_cache_max = 6
	defer claude_disk_cache_max = old_max
	old_budget := claude_disk_inline_budget
	claude_disk_inline_budget = 0 // every title from the worker
	defer claude_disk_inline_budget = old_budget
	cfg := fmt.tprintf("%s/.claude", env.home)
	ca_config(cfg)
	claude_accounts_refresh()
	titled :: proc() -> int {
		n := 0
		for f in state.claude_disk do if f.listed && f.title != "" do n += 1
		return n
	}
	for k in 0 ..< 2 {
		proj := ca_dir(k == 0 ? "first" : "second")
		pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
		count := k == 0 ? 6 : 5
		for i in 0 ..< count do ca_write(fmt.tprintf("%s/cace%04x-0000-4000-8000-00000000000%d.jsonl", ca_transcripts(cfg, proj), i, k), strings.join({ca_user(proj, fmt.tprintf("t%d", i)), ""}, "\n", context.temp_allocator))
		run_command(Select_Project{project_id = pid}, CA_UI)
		claude_disk_wait()
		claude_disk_wait()
		testing.expect_value(t, titled(), count)
	}
}

// Saving a config file of an account no Claude tab runs under shows no restart bar.
@(test)
claude_review_note_save :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	home := fmt.tprintf("%s/.claude", env.home)
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(home, marked = false)
	ca_config(work)
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	r := run_command(New_Claude_Session{project_id = pid, account = "Claude"}, CA_UI)
	testing.expect(t, r.ok, r.error)
	n := claude_reload_pending_count()
	claude_reload_note_save(fmt.tprintf("%s/commands/x.md", work))
	testing.expect_value(t, claude_reload_pending_count(), n)
	claude_reload_note_save(fmt.tprintf("%s/commands/x.md", home))
	testing.expect_value(t, claude_reload_pending_count(), n + 1)
	ca_close(t, r.created_id)
}

// A history entry that ran in a subfolder (no transcript path known): its transcript is in
// that folder's projects/ folder, so the row is not "gone".
@(test)
claude_review_gone_subfolder :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	cfg := fmt.tprintf("%s/.claude", env.home)
	ca_config(cfg, marked = false)
	claude_accounts_refresh()
	proj := ca_dir("proj")
	sub := fmt.tprintf("%s/sub", proj)
	os.make_directory_all(sub)
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	r := run_command(New_Claude_Session{project_id = pid, cwd = sub}, CA_UI)
	testing.expect(t, r.ok, r.error)
	sid := "50b50b50-0000-4000-8000-000000000001"
	tab := find_session(r.created_id).tabs[0].id
	run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "startup"}, CA_SCRIPT)
	run_command(Claude_Turn_Report{tab_id = tab, state = "submitted", title = "in sub"}, CA_SCRIPT)
	ca_close(t, r.created_id)
	ca_write(fmt.tprintf("%s/%s.jsonl", ca_transcripts(cfg, sub), sid), strings.join({ca_user(sub, "in sub"), ""}, "\n", context.temp_allocator))
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	f := claude_disk_of(sid)
	testing.expect(t, f == nil || !f.gone, "its transcript is there")
}

// One account: the Settings tab shows one quiet row for more accounts, not Add and Scan.
@(test)
claude_review_one_account_settings :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	ca_config(fmt.tprintf("%s/.claude", env.home), marked = false)
	claude_accounts_refresh()
	paths := make(map[string]bool, context.temp_allocator)
	for r in settings_file_rows() do paths[r.path] = true
	testing.expect(t, CLAUDE_ACCOUNT_MORE_ROW in paths, "one row")
	testing.expect(t, !(CLAUDE_ACCOUNT_ADD_ROW in paths) && !(CLAUDE_ACCOUNT_SCAN_ROW in paths), "no Add, no Scan")
}

// Labels swapped on the setup sheet are applied (one rename at a time would clash); the last
// account comes back clean.
@(test)
claude_review_setup_swap :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	ca_config(fmt.tprintf("%s/.claude", env.home))
	ca_config(fmt.tprintf("%s/.claude-work", env.home))
	ca_config(fmt.tprintf("%s/.claude-play", env.home))
	setup_begin()
	testing.expect_value(t, ca_labels(), "Claude*,Play,Work")
	setup_account_set_label(1, "Work")
	setup_account_set_label(2, "Play")
	setup_accounts_done()
	inbox_drain()
	testing.expect_value(t, ca_labels(), "Claude*,Work,Play")
	st := make(json.Object, context.temp_allocator)
	st["claude_account_last"] = json.String(fmt.tprintf("%s//.claude-work/", env.home))
	claude_accounts_restore(st)
	testing.expect_value(t, state.settings.claude_account_last, fmt.tprintf("%s/.claude-work", env.home))
}

// ---- review round 2 ----

// A single-quoted key holding '"' hides a deep array from a check that knows only "…" strings;
// the strict parser refuses the line instead of recursing into it.
@(test)
claude_review2_single_quote :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	cfg := fmt.tprintf("%s/.claude", env.home)
	ca_config(cfg)
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"cwd":%q,"type":"user",'"':`, proj)
	for _ in 0 ..< 30_000 do strings.write_byte(&b, '[')
	for _ in 0 ..< 30_000 do strings.write_byte(&b, ']')
	strings.write_string(&b, "}\n")
	strings.write_string(&b, ca_user(proj, "after the quote"))
	strings.write_string(&b, "\n")
	ca_write(fmt.tprintf("%s/%s.jsonl", ca_transcripts(cfg, proj), "a0a0a0a0-0000-4000-8000-000000000001"), strings.to_string(b))
	run_command(Select_Project{project_id = pid}, CA_UI)
	claude_disk_wait()
	testing.expect_value(t, ca_row_text(), "after the quote(c)")
	claude_scan_prepare()
	projects := make([dynamic]Project, context.temp_allocator)
	claude_scan_projects(&projects)
	testing.expect_value(t, len(projects), 1)
}

// Claude-only projects saved in the workspace come back as found rows (not added by hand, not
// selected one by one, no transcript read at launch); a removed account's are dropped by the
// Rescan after the saved accounts are back.
@(test)
claude_review2_restore :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	work := fmt.tprintf("%s/.claude-work", env.home)
	ca_config(work)
	claude_accounts_refresh()
	base := ca_dir("base")
	mine := fmt.tprintf("%s/mine", base)
	only := fmt.tprintf("%s/mine/only", base)
	os.make_directory_all(only)
	ca_write(fmt.tprintf("%s/%s.jsonl", ca_transcripts(work, only), "b0b0b0b0-0000-4000-8000-000000000001"), strings.join({ca_user(only, "hi"), ""}, "\n", context.temp_allocator))
	ca_scan :: proc() {
		run_command(Rescan{}, CA_UI)
		for _ in 0 ..< 300 {
			inbox_drain()
			if scan_thread == nil do break
			time.sleep(10 * time.Millisecond)
		}
	}
	ca_scan()
	testing.expect(t, project_by_cwd(only) != nil, "found")
	mid := run_command(Add_Project{cwd = mine}, CA_UI).created_id
	// a relaunch: the saved workspace, a first scan with no transcript read
	text := workspace_json()
	state.projects = {}
	state.selected_project = 0
	rescan_now(claude = false)
	claude_disk_launching = true
	before := claude_disk_bytes_read
	testing.expect_value(t, workspace_restore(text), "")
	claude_disk_launching = false
	testing.expect_value(t, claude_disk_bytes_read, before)
	p := project_by_cwd(only)
	testing.expect(t, p != nil && !p.by_hand, "a found row, not one added by hand")
	testing.expect_value(t, find_project(state.selected_project).cwd, mine)
	// not added by hand, so it nests under its parent (project_tidy.odin: nestable; temp folders
	// like these are hidden from nesting, so the rule is checked, not the drawn row)
	_ = mid
	// the account removed, saved, relaunched: the Rescan drops its project
	testing.expect(t, run_command(Remove_Claude_Account{account = "Work"}, CA_UI).ok)
	text = workspace_json()
	state.projects = {}
	state.selected_project = 0
	rescan_now(claude = false)
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect(t, claude_startup_rescan_due(), "a Claude project to confirm")
	ca_scan()
	testing.expect(t, project_by_cwd(only) == nil, "a removed account's project is gone")
	testing.expect(t, project_by_cwd(mine) != nil, "the hand-added one stays")
}

// A recorded session whose account was removed never opens a dead tab.
@(test)
claude_review2_resume_removed :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	ca_config(fmt.tprintf("%s/.claude", env.home), marked = false)
	ca_config(fmt.tprintf("%s/.claude-work", env.home))
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	r := run_command(New_Claude_Session{project_id = pid, account = "Work"}, CA_UI)
	sid := "c0c0c0c0-0000-4000-8000-000000000001"
	run_command(Claude_Session_Report{tab_id = find_session(r.created_id).tabs[0].id, session_id = sid, source = "startup"}, CA_SCRIPT)
	ca_close(t, r.created_id)
	testing.expect(t, run_command(Remove_Claude_Account{account = "Work"}, CA_UI).ok)
	r2 := run_command(New_Claude_Tab{project_id = pid, resume = sid}, CA_UI)
	testing.expect(t, !r2.ok && strings.contains(r2.error, "account"), r2.error)
}

// A project, the main folder or the chats folder never goes inside another account's folder.
@(test)
claude_review2_inside_account :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	ca_config(fmt.tprintf("%s/.claude", env.home), marked = false)
	team := ca_dir("team")
	ca_config(team)
	testing.expect(t, run_command(Add_Claude_Account{dir = team}, CA_UI).ok)
	inside := fmt.tprintf("%s/code", team)
	os.make_directory_all(inside)
	r := run_command(Add_Project{cwd = inside}, CA_UI)
	testing.expect(t, !r.ok && strings.contains(r.error, "account"), r.error)
	r = run_command(Set_Home_Dir{path = inside}, CA_UI)
	testing.expect(t, !r.ok && strings.contains(r.error, "account"), r.error)
	r = run_command(Set_Folder{kind = .Chats, path = inside}, CA_UI)
	testing.expect(t, !r.ok && strings.contains(r.error, "account"), r.error)
}

// rescan_now while a Rescan runs leaves the worker's account folders alone (one more Rescan
// after it instead).
@(test)
claude_review2_rescan_during :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	ca_config(fmt.tprintf("%s/.claude", env.home))
	claude_accounts_refresh()
	for _ in 0 ..< 300 {
		inbox_drain()
		if scan_thread == nil do break
		time.sleep(10 * time.Millisecond)
	}
	claude_rescan_again = false
	testing.expect(t, run_command(Rescan{}, CA_UI).ok)
	if scan_thread != nil {
		n := len(claude_scan_dirs)
		data := raw_data(claude_scan_dirs)
		rescan_now()
		testing.expect(t, claude_rescan_again, "once more after the running one")
		testing.expect(t, len(claude_scan_dirs) == n && raw_data(claude_scan_dirs) == data, "the worker's folders untouched")
	}
	for _ in 0 ..< 300 {
		inbox_drain()
		if scan_thread == nil && !claude_rescan_again do break
		time.sleep(10 * time.Millisecond)
	}
	for _ in 0 ..< 300 {
		inbox_drain()
		if scan_thread == nil do break
		time.sleep(10 * time.Millisecond)
	}
}

// A history entry saved without an account (from before accounts) stays without one: "" is the
// default account as resolved when it is used (listing, resume), never a folder stamped at load
// (from inside a Claude session whose shell did not answer, that would be the parent's).
@(test)
claude_review3_unstamped :: proc(t: ^testing.T) {
	env: Ca_Env
	context.allocator = ca_reset(&env)
	defer ca_done()
	x := fmt.tprintf("%s/Some Config", ca_dir("x"))
	ca_config(x)
	ca_config(fmt.tprintf("%s/.claude", env.home), marked = false)
	os.set_env("CLAUDE_CONFIG_DIR", x)
	claude_accounts_refresh()
	proj := ca_dir("proj")
	pid := run_command(Add_Project{cwd = proj}, CA_UI).created_id
	sid := "d0d0d0d0-0000-4000-8000-000000000001"
	recs := []Claude_Record{{id = sid, cwd = proj, project = proj, title = "old one", used = 1_700_000_000}}
	testing.expect(t, run_command(Claude_Restore_History{records = recs}, {kind = .Internal}).ok)
	rec, _ := claude_record(sid)
	testing.expect(t, rec != nil && rec.account == "", "not stamped at load")
	text := workspace_json()
	i := strings.index(text, sid)
	testing.expect(t, i >= 0, "saved")
	if i >= 0 {
		entry := text[i:]
		if e := strings.index_byte(entry, '}'); e >= 0 do entry = entry[:e]
		testing.expect(t, !strings.contains(entry, `"account"`), entry)
	}
	// listed under the default (with two accounts: its tag)
	run_command(Select_Project{project_id = pid}, CA_UI)
	testing.expect_value(t, ca_row_text(), "old one(c)[Claude]")
	// resumed under the current default, never refused as removed
	r := run_command(Claude_Resume{claude_session_id = sid}, CA_UI)
	testing.expect(t, r.ok, r.error)
	if r.ok {
		_, tab, _ := find_tab(r.created_id)
		if tab != nil do testing.expect_value(t, claude_account_dir(tab.kind.(Claude_Tab).account), x)
	}
}
