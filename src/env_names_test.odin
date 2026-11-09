package main

// The rename's bridge (0.1.7, env_names.odin, platform.odin, app_tab.odin): the old pi-desk
// names keep working beside the new ones.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
rn_tmp :: proc(name: string) -> string {
	d := fmt.aprintf("%s/deckhand-rename-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), name, time.now()._nsec, allocator = runtime.heap_allocator())
	os.make_directory_all(d)
	return d
}

// Every name Deckhand sets for a Claude tab, an app tab or a job run that something outside reads
// goes out under both names, the old right after the new, with the same value; nothing else gets a
// twin (CLAUDE_TAB, CLAUDE_READONLY and CLAUDE_ACCOUNT are read by no one: review L1, an old
// account marker would reach claude's Bash).
@(test)
env_both_names_set :: proc(t: ^testing.T) {
	in_env := []string {
		"DECKHAND_SOCKET=/s", "DECKHAND_CLAUDE_TOKEN=abc", "DECKHAND_CLI=/A/MacOS/deckhand-cli", "DECKHAND_SHOTS_DIR=/d",
		"DECKHAND_CLAUDE_TAB=7", "DECKHAND_CLAUDE_READONLY=1", "DECKHAND_CLAUDE_ACCOUNT=", "!CLAUDE_CONFIG_DIR",
		"DECKHAND_TOKEN=t", "DECKHAND_APP=1", "DECKHAND_JOB=j", "DECKHAND_RUN=r", "DECKHAND_RUN_DIR=/r", "DECKHAND_SCHEDULED_AT=2026",
		"DECKHAND_CONTROL_TOKEN=c", "PI_KIT_NOTES_DIR=/n", "DECKHAND_SIGN_IDENTITY=x", "TERM=x",
	}
	out := core.env_with_legacy(in_env)
	got := strings.join(out, " ", context.temp_allocator)
	want := "DECKHAND_SOCKET=/s PI_DESK_SOCKET=/s DECKHAND_CLAUDE_TOKEN=abc PI_DESK_CLAUDE_TOKEN=abc DECKHAND_CLI=/A/MacOS/deckhand-cli PI_DESK_CLI=/A/MacOS/deckhand-cli DECKHAND_SHOTS_DIR=/d PI_DESK_SHOTS_DIR=/d DECKHAND_CLAUDE_TAB=7 DECKHAND_CLAUDE_READONLY=1 DECKHAND_CLAUDE_ACCOUNT= !CLAUDE_CONFIG_DIR DECKHAND_TOKEN=t PI_DESK_TOKEN=t DECKHAND_APP=1 PI_DESK_APP=1 DECKHAND_JOB=j PI_DESK_JOB=j DECKHAND_RUN=r PI_DESK_RUN=r DECKHAND_RUN_DIR=/r PI_DESK_RUN_DIR=/r DECKHAND_SCHEDULED_AT=2026 PI_DESK_SCHEDULED_AT=2026 DECKHAND_CONTROL_TOKEN=c PI_KIT_NOTES_DIR=/n DECKHAND_SIGN_IDENTITY=x TERM=x"
	testing.expect_value(t, got, want)
	// every name a scrub drops is one Deckhand sets or reads, under both names
	for s in core.DESK_SET_ENV {
		testing.expectf(t, core.env_desk_set(strings.concatenate({"DECKHAND_", s}, context.temp_allocator)) && core.env_desk_set(strings.concatenate({"PI_DESK_", s}, context.temp_allocator)), "%s: both names", s)
	}
	for s in core.DESK_LEGACY_SET {
		found := false
		for x in core.DESK_SET_ENV do if x == s do found = true
		testing.expectf(t, found, "%s: a twin of a name Deckhand sets", s)
	}
}

// The scrubs are an explicit list, not the DECKHAND_ prefix (the plan's R6): the user's own
// DECKHAND_SIGN_IDENTITY or DECKHAND_RELEASE reaches a shell tab and comes from the login shell.
@(test)
env_scrubs_are_explicit :: proc(t: ^testing.T) {
	for k in ([]string{"DECKHAND_SOCKET", "PI_DESK_SOCKET", "DECKHAND_CLAUDE_TOKEN", "PI_DESK_CLI", "DECKHAND_GUI_LAUNCH", "PI_DESK_CEF_SHARED_TEXTURE", "DECKHAND_SCHEDULED_AT"}) {
		testing.expectf(t, core.env_desk_set(k), "%s is Deckhand's", k)
		testing.expectf(t, core.env_desk_owned(k), "%s is Deckhand's", k)
	}
	for k in ([]string{"DECKHAND_SIGN_IDENTITY", "DECKHAND_SIGN_REQUIRED", "DECKHAND_RELEASE", "DECKHAND_NO_CEF", "DECKHAND", "DECKHAND_", "DECKHAND_SOCKETX", "PATH", "PI_KIT_READONLY", "PI_DESKTOP"}) {
		testing.expectf(t, !core.env_desk_set(k), "%s passes the tab scrub", k)
	}
	for k in ([]string{"DECKHAND_SIGN_IDENTITY", "DECKHAND_RELEASE", "PATH"}) do testing.expectf(t, !core.env_desk_owned(k), "%s comes from the login shell", k)
	testing.expect(t, core.env_desk_owned("PI_DESK_ANYTHING"), "every old name stays Deckhand's")
	// development knobs read outside hook_env (scripts/check-env-reads.py HOOK_ONLY) never come
	// from the login shell either (review L3)
	when core.TEST_HOOKS do for k in ([]string{"DECKHAND_CEF_SPARE", "DECKHAND_CEF_NETLOG", "DECKHAND_HOLDER_HOOKS"}) do testing.expectf(t, core.env_desk_owned(k), "%s is a dev knob", k)
	when core.TEST_HOOKS do testing.expect(t, core.env_desk_owned("DECKHAND_SCRIPT") && core.env_desk_owned("DECKHAND_DATA_DIR"), "a test hook never comes from the shell")

	// the login shell's environment: both families of Deckhand's own dropped, the user's knobs kept
	M :: core.LOGIN_ENV_MARK
	vars, ok := core.login_env_parse(M + "PATH=/a\x00PI_DESK_SCRIPT=x\x00PI_DESK_SOCKET=/s\x00DECKHAND_SOCKET=/s\x00DECKHAND_CLAUDE_TOKEN=t\x00DECKHAND_SIGN_IDENTITY=Me\x00DECKHAND_RELEASE=1\x00" + M)
	testing.expect(t, ok)
	testing.expect_value(t, strings.join(vars, "|", context.temp_allocator), "PATH=/a|DECKHAND_SIGN_IDENTITY=Me|DECKHAND_RELEASE=1")

	// a tab's environment (term.odin child_env): what Deckhand set before, either name, never inherited
	keys := []string{"PI_DESK_SOCKET", "PI_DESK_CLAUDE_TOKEN", "DECKHAND_CLI", "DECKHAND_SIGN_IDENTITY", "DECKHAND_CEF_SHARED_TEXTURE", "PI_DESK_CEF_SHARED_TEXTURE"}
	for k in keys do os.set_env(k, "/inherited")
	defer for k in keys do os.unset_env(k)
	env := core.child_env({"DECKHAND_SOCKET=/new"})
	has :: proc(env: []string, k: string) -> bool {
		for e in env do if strings.has_prefix(e, k) && strings.has_prefix(e[len(k):], "=") do return true
		return false
	}
	testing.expect(t, !has(env, "PI_DESK_SOCKET") && !has(env, "PI_DESK_CLAUDE_TOKEN") && !has(env, "DECKHAND_CLI"), "inherited names of Deckhand's dropped")
	testing.expect(t, has(env, "DECKHAND_SIGN_IDENTITY"), "the user's own DECKHAND_ variable kept")
	// the user's documented workaround passes to shell tabs, as on main (a Deckhand run from one)
	testing.expect(t, has(env, "DECKHAND_CEF_SHARED_TEXTURE") && has(env, "PI_DESK_CEF_SHARED_TEXTURE"), "CEF_SHARED_TEXTURE passes")
	testing.expect(t, has(env, "DECKHAND_SOCKET"), "what this tab is given kept")
	testing.expect(t, slice_has(env, "TERM_PROGRAM=Deckhand"))
}

@(private = "file")
slice_has :: proc(s: []string, x: string) -> bool {
	for e in s do if e == x do return true
	return false
}

// The data dir: ~/Library/Application Support/Deckhand when it is there or neither is, else the
// old .../pi-desk (every install up to 0.1.6). Nothing is moved (0.1.8 does that).
@(test)
data_dir_reads_both :: proc(t: ^testing.T) {
	home := rn_tmp("home")
	defer {os.remove_all(home); delete(home, runtime.heap_allocator())}
	new, old := core.data_dir_names(home)
	when ODIN_OS == .Darwin {
		testing.expect_value(t, new, fmt.tprintf("%s/Library/Application Support/Deckhand", home))
		testing.expect_value(t, old, fmt.tprintf("%s/Library/Application Support/pi-desk", home))
	}
	testing.expect_value(t, core.data_dir_under(home, context.temp_allocator), new) // a new install: the new name
	os.make_directory_all(old)
	testing.expect_value(t, core.data_dir_under(home, context.temp_allocator), old) // 0.1.6's data: read where it is
	testing.expect(t, !os.exists(new), "nothing moved or made")
	os.make_directory_all(new)
	testing.expect_value(t, core.data_dir_under(home, context.temp_allocator), new) // both: the new one
	// a link at the new place (0.1.8's move leaves one at the old place; a user's own here) counts
	os.remove(new)
	os.symlink(old, new)
	testing.expect_value(t, core.data_dir_under(home, context.temp_allocator), new)
	os.remove(new)
	// a file, not a folder, at the new place: the old folder still wins
	_ = os.write_entire_file(new, transmute([]byte)string("x"))
	testing.expect_value(t, core.data_dir_under(home, context.temp_allocator), old)
}

// The project file: .deckhand/apps.json, else the old .pi-desk/apps.json; both: .deckhand's.
@(test)
apps_json_reads_both :: proc(t: ^testing.T) {
	proj := rn_tmp("proj")
	defer {os.remove_all(proj); delete(proj, runtime.heap_allocator())}
	testing.expect_value(t, len(core.app_entries(proj)), 0)
	testing.expect(t, strings.contains(core.app_not_declared(proj, "nope"), ".deckhand/apps.json"), core.app_not_declared(proj, "nope"))
	testing.expect_value(t, core.app_json_path(proj), fmt.tprintf("%s/.deckhand/apps.json", proj))
	os.make_directory_all(fmt.tprintf("%s/.pi-desk", proj))
	_ = os.write_entire_file(fmt.tprintf("%s/.pi-desk/apps.json", proj), transmute([]byte)string(`{"apps":[{"name":"old","argv":["true"]}]}`))
	e := core.app_entries(proj)
	testing.expect(t, len(e) == 1 && e[0].name == "old", "the old project file is read")
	// a refusal names the file it read (review polish)
	why := core.app_not_declared(proj, "nope")
	testing.expect(t, strings.contains(why, ".pi-desk/apps.json") && !strings.contains(why, ".deckhand/"), why)
	os.make_directory_all(fmt.tprintf("%s/.deckhand", proj))
	_ = os.write_entire_file(fmt.tprintf("%s/.deckhand/apps.json", proj), transmute([]byte)string(`{"apps":[{"name":"new","argv":["true"]}]}`))
	e = core.app_entries(proj)
	testing.expect(t, len(e) == 1 && e[0].name == "new", "both: the new one only")
	testing.expect(t, strings.contains(core.app_not_declared(proj, "nope"), ".deckhand/apps.json"), core.app_not_declared(proj, "nope"))
	testing.expect(t, os.exists(fmt.tprintf("%s/.pi-desk/apps.json", proj)), "the old one is left where it is")
}

// Review M1: a development or test build reads a test hook's old PI_DESK_ name when the new one is
// unset (the user's dev launcher and forge's scripts set PI_DESK_DATA_DIR), with a one-line
// warning naming the new variable; the new name wins when both are set.
@(test)
hook_env_reads_old_names :: proc(t: ^testing.T) {
	when core.TEST_HOOKS {
		saved_new, had_new := os.lookup_env("DECKHAND_DATA_DIR", context.temp_allocator)
		saved_old, had_old := os.lookup_env("PI_DESK_DATA_DIR", context.temp_allocator)
		defer {
			if had_new do os.set_env("DECKHAND_DATA_DIR", saved_new); else do os.unset_env("DECKHAND_DATA_DIR")
			if had_old do os.set_env("PI_DESK_DATA_DIR", saved_old); else do os.unset_env("PI_DESK_DATA_DIR")
			core.hook_warned = {}
			core.hook_last_warning = ""
		}
		os.unset_env("DECKHAND_DATA_DIR")
		os.set_env("PI_DESK_DATA_DIR", "/tmp/old-dev-data")
		core.hook_warned = {}
		testing.expect_value(t, core.data_dir(context.temp_allocator), "/tmp/old-dev-data")
		testing.expect(t, strings.contains(core.hook_last_warning, "PI_DESK_DATA_DIR") && strings.contains(core.hook_last_warning, "DECKHAND_DATA_DIR"), core.hook_last_warning)
		v, ok := core.hook_lookup(.Data_Dir)
		testing.expect(t, ok && v == "/tmp/old-dev-data", "hook_lookup too")
		os.set_env("DECKHAND_DATA_DIR", "/tmp/new-dev-data")
		testing.expect_value(t, core.data_dir(context.temp_allocator), "/tmp/new-dev-data")
		os.unset_env("PI_DESK_DATA_DIR")
		os.unset_env("DECKHAND_DATA_DIR")
		_, ok = core.hook_lookup(.Data_Dir)
		testing.expect(t, !ok, "neither set")
	}
}

// Review L2: both data dirs there: the old one while a holder answers under it (its held sessions
// are never orphaned), else the new one; either way it is logged.
@(test)
data_dir_both_with_holder :: proc(t: ^testing.T) {
	home := fmt.aprintf("/tmp/dhr-%d", time.now()._nsec % 1_000_000_000, allocator = runtime.heap_allocator())
	defer {os.remove_all(home); delete(home, runtime.heap_allocator())}
	new, old := core.data_dir_names(home)
	os.make_directory_all(new)
	os.make_directory_all(fmt.tprintf("%s/run", old))
	core.data_dir_note = ""
	testing.expect_value(t, core.data_dir_pick(new, old), new)
	testing.expect(t, strings.contains(core.data_dir_note, "both"), core.data_dir_note)
	// a stale socket file (nothing listening) does not count
	sp := fmt.tprintf("%s/run/holder-abcd1234.sock", old)
	_ = os.write_entire_file(sp, transmute([]byte)string(""))
	testing.expect_value(t, core.data_dir_pick(new, old), new)
	os.remove(sp)
	fd, ok := core.sock_listen(sp)
	testing.expect(t, ok, sp)
	defer {core.sock_close(fd); core.sock_unlink(sp)}
	testing.expect_value(t, core.data_dir_pick(new, old), old)
	testing.expect(t, strings.contains(core.data_dir_note, "holder"), core.data_dir_note)
}
