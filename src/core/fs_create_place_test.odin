package core

// create_file and create_dir in a credential place (fs_credential_place: pi's agent folder,
// Claude's config folders and any folder holding .credentials.json or .claude.json, Codex's
// homes, a .codex folder holding auth.json): refused for anyone but the user here, as rename and
// delete are, also when the user confirms another caller's create. All in a scratch HOME.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// A clean State, a scratch HOME with one project in it (real paths), PI_CODING_AGENT_DIR unset.
@(private = "file")
psetup :: proc(tag: string) -> (home, proj: string, tab: u64) {
	state = State{}
	home = fmt.tprintf("%s/dhp-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(fmt.tprintf("%s/proj", home))
	home = fs_real(home, context.allocator)
	os.set_env("HOME", home)
	os.unset_env("PI_CODING_AGENT_DIR")
	proj = fmt.aprintf("%s/proj", home)
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(proj), label = "proj"})
	// a session in it with an agent's tab: a Panel caller's own folder is the project
	s := Open_Session{id = new_id(), project_id = state.projects[0].id, cwd = strings.clone(proj)}
	tab = new_id()
	append(&s.tabs, Tab{id = tab, kind = Pi_Tab{}, title = "pi", status = .Exited})
	append(&state.open_sessions, s)
	// places inside the project: a .codex folder with auth.json, a Claude profile folder
	os.make_directory_all(fmt.tprintf("%s/.codex", proj))
	_ = os.write_entire_file(fmt.tprintf("%s/.codex/auth.json", proj), transmute([]u8)string("{}"))
	os.make_directory_all(fmt.tprintf("%s/prof", proj))
	_ = os.write_entire_file(fmt.tprintf("%s/prof/.claude.json", proj), transmute([]u8)string("{}"))
	return
}

@(test)
fs_create_refused_in_credential_places :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	old_pi, had_pi := os.lookup_env("PI_CODING_AGENT_DIR", context.allocator)
	home, proj, tab := psetup("create")
	defer {
		os.set_env("HOME", old_home)
		delete(old_home)
		if had_pi do os.set_env("PI_CODING_AGENT_DIR", old_pi)
		os.remove_all(home)
		state = State{}
	}
	others := []Caller{{kind = .Control}, {kind = .UI, web = true}, {kind = .UI, hub = true}, {kind = .Panel, tab_id = tab}, {kind = .Panel, tab_id = tab, claude = true}, {kind = .Script}}
	for c, i in others {
		for rel in ([]string{".codex/config.toml", "prof/settings.json", "prof/sub/x.md"}) {
			_, e := fs_create_file(fmt.tprintf("%s/%s", proj, rel), c)
			testing.expectf(t, e == CREDENTIAL_PLACE_REFUSED, "file %s by %v: %q", rel, c, e)
		}
		for rel in ([]string{".codex/hooks", "prof/sub"}) {
			_, e := fs_create_dir(fmt.tprintf("%s/%s", proj, rel), c)
			testing.expectf(t, e == CREDENTIAL_PLACE_REFUSED, "dir %s by %v: %q", rel, c, e)
		}
		testing.expect(t, !os.exists(fmt.tprintf("%s/.codex/config.toml", proj)) && !os.exists(fmt.tprintf("%s/prof/sub", proj)), "nothing made")
		// an ordinary project path: for everyone
		_, e := fs_create_file(fmt.tprintf("%s/f%d.txt", proj, i), c)
		testing.expectf(t, e == "", "ordinary file by %v: %q", c, e)
		_, e = fs_create_dir(fmt.tprintf("%s/d%d/e", proj, i), c)
		testing.expectf(t, e == "", "ordinary dir by %v: %q", c, e)
	}
	// the user here may
	_, e := fs_create_file(fmt.tprintf("%s/.codex/config.toml", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "")
	_, e = fs_create_dir(fmt.tprintf("%s/prof/sub", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "")
}

// Through the command: refused before anything is asked; a create the user confirms runs by the
// asker's rules, so a place made while it waits still refuses it.
@(test)
fs_create_place_confirmed_by_the_user_still_refused :: proc(t: ^testing.T) {
	when TEST_HOOKS {
		context.allocator = runtime.heap_allocator()
		old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
		old_pi, had_pi := os.lookup_env("PI_CODING_AGENT_DIR", context.allocator)
		home, proj, _ := psetup("confirm")
		defer {
			os.set_env("HOME", old_home)
			delete(old_home)
			if had_pi do os.set_env("PI_CODING_AGENT_DIR", old_pi)
			os.remove_all(home)
			state = State{}
		}
		ctl := Caller{kind = .Control}
		// already a place: refused at once, nothing asked
		r := run_command(Create_File{path = fmt.tprintf("%s/.codex/config.toml", proj)}, ctl)
		testing.expect_value(t, r.error, CREDENTIAL_PLACE_REFUSED)
		testing.expect_value(t, len(state.pending_confirmations), 0)
		r = run_command(Create_Dir{path = fmt.tprintf("%s/prof/sub", proj)}, ctl)
		testing.expect_value(t, r.error, CREDENTIAL_PLACE_REFUSED)
		testing.expect_value(t, len(state.pending_confirmations), 0)
		// not yet a place: asked; auth.json arrives while it waits; the user confirms
		os.make_directory_all(fmt.tprintf("%s/y/.codex", proj))
		for dir in ([]bool{false, true}) {
			path := fmt.tprintf("%s/y/.codex/%s", proj, dir ? "d" : "config.toml")
			os.remove(fmt.tprintf("%s/y/.codex/auth.json", proj))
			r = dir ? run_command(Create_Dir{path = path}, ctl) : run_command(Create_File{path = path}, ctl)
			testing.expect_value(t, r.error, "needs_confirmation")
			if len(state.pending_confirmations) != 1 do return
			tok := strings.clone(state.pending_confirmations[0].token, context.temp_allocator)
			_ = os.write_entire_file(fmt.tprintf("%s/y/.codex/auth.json", proj), transmute([]u8)string("{}"))
			r = dir ? run_command(Create_Dir{path = path, confirm = tok}, UI_HERE) : run_command(Create_File{path = path, confirm = tok}, UI_HERE)
			testing.expect_value(t, r.error, CREDENTIAL_PLACE_REFUSED)
			testing.expect(t, !os.exists(path), "not made")
			testing.expect_value(t, len(state.pending_confirmations), 0)
		}
		// the user's own create there: made
		r = run_command(Create_File{path = fmt.tprintf("%s/.codex/config.toml", proj)}, UI_HERE)
		testing.expect(t, r.ok, r.error)
	}
}
