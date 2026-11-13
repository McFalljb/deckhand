package main

// show_file: a session's own agent (a pi tab's bridge, a Claude tab's CLI: caller panel) shows the
// user a file: a Markdown file in a Markdown tab (rendered, following the disk, an anchor), any
// other text file in an editor tab (a line). The tab opens in the agent's own session, right after
// the agent's tab, behind the user's view; never in another session. Display only: any file the
// user could open (outside the project too), never a credentials file; binary, huge, missing
// files and folders are refused with a hint. Agents still cannot edit editor tabs. The live side
// is tests/scripts/agent-show.sh.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core"

// Two sessions in real folders (a: a pi tab, a Claude tab and a shell tab; b on screen), Home,
// and a folder outside every project.
@(private = "file")
sf_reset :: proc(t: ^testing.T) -> (a, b, home: u64, dir, outside: string) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{}
	core.platform, win_os = {}, {}
	dir = fmt.aprintf("build/test-data/show-file-%d", os.get_pid())
	os.remove_all(dir)
	for name in ([]string{"alpha", "beta"}) {
		cwd, _ := filepath.join({dir, name}, context.allocator)
		os.make_directory_all(strings.concatenate({cwd, "/docs"}, context.temp_allocator))
		_ = os.write_entire_file(strings.concatenate({cwd, "/README.md"}, context.temp_allocator), transmute([]u8)string("# Title\n\n## Setup\n\ntext\n"))
		_ = os.write_entire_file(strings.concatenate({cwd, "/notes.txt"}, context.temp_allocator), transmute([]u8)string("one\ntwo\nthree\nfour\n"))
		_ = os.write_entire_file(strings.concatenate({cwd, "/docs/guide.md"}, context.temp_allocator), transmute([]u8)string("# Guide\n"))
		append(&state.projects, core.Project{id = core.new_id(), cwd = core.fs_real(cwd)})
		s := core.Open_Session{id = core.new_id(), pi_session_id = fmt.aprintf("pi-%s", name), cwd = core.fs_real(cwd), project_id = state.projects[len(state.projects) - 1].id}
		append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
		append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Claude_Tab{}, title = "claude", status = .Running})
		append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Shell_Tab{}, title = "zsh", status = .Running})
		s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
	}
	h := core.Open_Session{id = core.new_id(), home = true}
	append(&h.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "Home", status = .Running})
	h.active_tab = h.tabs[0].id
	append(&state.open_sessions, h)
	state.home = h.id
	state.current_session = state.open_sessions[1].id // the user looks at b
	outside = fmt.aprintf("%s/outside", dir)
	os.make_directory_all(outside)
	_ = os.write_entire_file(strings.concatenate({outside, "/sre-questions.md"}, context.temp_allocator), transmute([]u8)string("# Questions\n"))
	_ = os.write_entire_file(strings.concatenate({outside, "/log.txt"}, context.temp_allocator), transmute([]u8)string("a\nb\n"))
	return state.open_sessions[0].id, state.open_sessions[1].id, h.id, dir, outside
}

@(private = "file")
sf_done :: proc(dir: string) {
	for &s in state.open_sessions {
		for tab in s.tabs {
			#partial switch _ in tab.kind {
			case core.Editor_Tab, core.Markdown_Tab: core.run_command(core.Close_Tab{tab_id = tab.id}, {kind = .Internal})
			}
		}
	}
	os.remove_all(dir)
}

@(private = "file")
sf_tab :: proc(session: u64, i: int) -> u64 {return core.find_session(session).tabs[i].id}

@(private = "file")
sf_count :: proc(session: u64) -> int {return len(core.find_session(session).tabs)}

@(private = "file")
sf_index :: proc(session: u64, tab_id: u64) -> int {
	for tab, i in core.find_session(session).tabs do if tab.id == tab_id do return i
	return -1
}

// A pi tab and a Claude tab show a Markdown file and a text file: the right tab kind, in their own
// session, right after their own tab, behind the user's view.
@(test)
show_file_own_session_next_to_the_agent :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, _, dir, _ := sf_reset(t)
	defer sf_done(dir)
	pi := core.Caller{kind = .Panel, tab_id = sf_tab(a, 0)}
	claude := core.Caller{kind = .Panel, tab_id = sf_tab(a, 1), claude = true}
	for caller in ([]core.Caller{pi, claude}) {
		testing.expectf(t, core.caller_may(caller, core.Show_File{}), "%v may send show_file", caller)
		active := core.find_session(a).active_tab
		nb := sf_count(b)
		// a Markdown file, relative to the session's folder, with an anchor
		r := core.run_command(core.Show_File{path = "README.md", anchor = "#setup"}, caller)
		testing.expectf(t, r.ok && r.created_id != 0, "shows README.md: %s", r.error)
		s, tab, _ := core.find_tab(r.created_id)
		testing.expect(t, s != nil && s.id == a, "in its own session")
		if tab != nil {
			mt, is := tab.kind.(core.Markdown_Tab)
			testing.expect(t, is, "a Markdown tab")
			testing.expect_value(t, mt.path, fmt.tprintf("%s/README.md", core.find_session(a).cwd))
			testing.expect(t, !mt.source, "rendered (the preview)")
			v := md_view_of(tab.id)
			testing.expect(t, v != nil && v.want == "setup", "scrolls to the anchor (# dropped)")
		}
		testing.expect_value(t, sf_index(a, r.created_id), sf_index(a, caller.tab_id) + 1)
		testing.expect_value(t, core.json_path(r.data, "kind"), "markdown")
		// a text file in an editor tab, at a line
		r2 := core.run_command(core.Show_File{path = "notes.txt", line = 3}, caller)
		testing.expectf(t, r2.ok, "shows notes.txt: %s", r2.error)
		s2, tab2, _ := core.find_tab(r2.created_id)
		testing.expect(t, s2 != nil && s2.id == a, "in its own session")
		if tab2 != nil {
			et, is := tab2.kind.(core.Editor_Tab)
			testing.expect(t, is && !et.preview, "an ordinary editor tab")
			e := editor_of(tab2.id)
			l, _ := ed_line_col(e, e.cursor)
			testing.expect_value(t, l, 3)
		}
		testing.expect_value(t, sf_index(a, r2.created_id), sf_index(a, caller.tab_id) + 1)
		testing.expect_value(t, core.json_path(r2.data, "kind"), "editor")
		// behind the user's view: the session on screen, a's active tab and b stay as they were
		testing.expect_value(t, state.current_session, b)
		testing.expect_value(t, core.find_session(a).active_tab, active)
		testing.expect_value(t, sf_count(b), nb)
		// naming its own session is fine; another is refused, nothing opened there
		r3 := core.run_command(core.Show_File{path = "docs/guide.md", session = a}, caller)
		testing.expectf(t, r3.ok, "its own session by id: %s", r3.error)
		r4 := core.run_command(core.Show_File{path = "notes.txt", session = b}, caller)
		testing.expectf(t, !r4.ok && strings.contains(r4.error, "own session") && core.json_path(r4.data, "code") == "other_session", "another session refused: %s", r4.error)
		testing.expect_value(t, sf_count(b), nb)
		// shown again: the same tab, not a second one, and still behind
		n := sf_count(a)
		r5 := core.run_command(core.Show_File{path = fmt.tprintf("%s/notes.txt", core.find_session(a).cwd), line = 1}, caller)
		testing.expect_value(t, r5.created_id, r2.created_id)
		testing.expect_value(t, sf_count(a), n)
		testing.expect_value(t, core.find_session(a).active_tab, active)
		testing.expect_value(t, state.current_session, b)
		e := editor_of(r2.created_id)
		l, _ := ed_line_col(e, e.cursor)
		testing.expect_value(t, l, 1)
		testing.expect_value(t, core.json_path(r5.data, "already_open"), "true")
		sf_done_tabs(a)
	}
}

@(private = "file")
sf_done_tabs :: proc(session: u64) {
	for {
		found := u64(0)
		for tab in core.find_session(session).tabs {
			#partial switch _ in tab.kind {
			case core.Editor_Tab, core.Markdown_Tab: found = tab.id
			}
		}
		if found == 0 do return
		core.run_command(core.Close_Tab{tab_id = found}, {kind = .Internal})
	}
}

// Paths: a file outside the project is shown (display only: the agent can read it anyway);
// credentials files never; missing files, folders, binary and huge files are refused with a hint;
// an anchor is for Markdown files only.
@(test)
show_file_paths_and_refusals :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir, outside := sf_reset(t)
	defer sf_done(dir)
	pi := core.Caller{kind = .Panel, tab_id = sf_tab(a, 0)}
	claude := core.Caller{kind = .Panel, tab_id = sf_tab(a, 1), claude = true}
	cwd := core.find_session(a).cwd
	_ = os.write_entire_file(strings.concatenate({cwd, "/.env"}, context.temp_allocator), transmute([]u8)string("TOKEN=dummy\n"))
	_ = os.write_entire_file(strings.concatenate({cwd, "/b.bin"}, context.temp_allocator), transmute([]u8)string("\x7fELF\x00\x01\x02"))
	// a sparse file over the editor's limit
	big := strings.concatenate({cwd, "/big.log"}, context.temp_allocator)
	fd := posix.open(strings.clone_to_cstring(big, context.temp_allocator), {.CREAT, .WRONLY}, {.IRUSR, .IWUSR})
	testing.expect(t, fd >= 0, "big file created")
	posix.ftruncate(fd, posix.off_t(core.EDITOR_MAX_BYTES + 1))
	posix.close(fd)
	for caller in ([]core.Caller{pi, claude}) {
		// outside the project: shown, in its own session
		r := core.run_command(core.Show_File{path = fmt.tprintf("%s/sre-questions.md", core.fs_real(outside))}, caller)
		testing.expectf(t, r.ok, "a Markdown file outside the project: %s", r.error)
		s, tab, _ := core.find_tab(r.created_id)
		testing.expect(t, s != nil && s.id == a, "in its own session")
		if tab != nil {
			_, is := tab.kind.(core.Markdown_Tab)
			testing.expect(t, is, "a Markdown tab")
		}
		r = core.run_command(core.Show_File{path = fmt.tprintf("%s/log.txt", core.fs_real(outside)), line = 2}, caller)
		testing.expectf(t, r.ok, "a text file outside the project: %s", r.error)
		n := sf_count(a)
		refused :: proc(t: ^testing.T, r: core.Result, want: string, hint := "", loc := #caller_location) {
			testing.expectf(t, !r.ok && strings.contains(r.error, want), "refused (%s): %s", want, r.error, loc = loc)
			testing.expectf(t, !strings.has_prefix(core.json_path(r.data, "code"), "<") && !strings.has_prefix(core.json_path(r.data, "hint"), "<"), "a code and a hint: %s", r.data, loc = loc)
			if hint != "" do testing.expectf(t, strings.contains(r.error, hint) || strings.contains(core.json_path(r.data, "hint"), hint), "with a hint (%s): %s %s", hint, r.error, r.data, loc = loc)
		}
		refused(t, core.run_command(core.Show_File{path = ".env"}, caller), "redentials")
		refused(t, core.run_command(core.Show_File{path = "nope.md"}, caller), "no such file", cwd)
		refused(t, core.run_command(core.Show_File{path = "docs"}, caller), "folder")
		refused(t, core.run_command(core.Show_File{path = "b.bin"}, caller), "Binary", "text")
		refused(t, core.run_command(core.Show_File{path = "big.log"}, caller), "Too large", "20 MB")
		refused(t, core.run_command(core.Show_File{path = "notes.txt", anchor = "x"}, caller), "anchor")
		refused(t, core.run_command(core.Show_File{path = ""}, caller), "path")
		testing.expect_value(t, sf_count(a), n)
		sf_done_tabs(a)
	}
}

// Who may send it: a session's own agents (pi, Claude), the
// user, scripts and control; never an app. An agent still has no command that edits an editor
// tab: it may show a file, the user edits it.
@(test)
show_file_callers_and_no_agent_edits :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, home, dir, _ := sf_reset(t)
	defer sf_done(dir)
	sa := core.find_session(a)
	ro_id := core.new_id()
	append(&sa.tabs, core.Tab{id = ro_id, kind = core.Claude_Tab{}, title = "claude", status = .Running})
	ro := core.Caller{kind = .Panel, tab_id = ro_id, claude = true}
	pi := core.Caller{kind = .Panel, tab_id = sf_tab(a, 0)}
	for c in ([]core.Caller{pi, ro, {kind = .Panel, tab_id = sf_tab(a, 1), claude = true}, {kind = .UI}, {kind = .Script}, {kind = .Control}, {kind = .Internal}}) {
		testing.expectf(t, core.caller_may(c, core.Show_File{}), "%v may send show_file", c)
	}
	testing.expect(t, !core.caller_may({kind = .App, tab_id = 5}, core.Show_File{}), "an app tab's program sends no commands")
	// a Claude tab shows files (display only)
	r := core.run_command(core.Show_File{path = "notes.txt"}, ro)
	testing.expectf(t, r.ok, "a Claude tab shows a file: %s", r.error)
	ed := r.created_id
	testing.expect_value(t, sf_index(a, ed), sf_index(a, ro_id) + 1)
	// ...and cannot edit it, nor can any agent: no command that changes an editor tab or a file
	e := editor_of(ed)
	testing.expect(t, e != nil && !e.readonly, "the user edits it as usual")
	for c in ([]core.Caller{ro, pi}) {
		for cmd in ([]core.Command{core.Save_File{tab_id = ed}, core.Reload_File{tab_id = ed}, core.Keep_Buffer{tab_id = ed}, core.Goto_Line{tab_id = ed, line = 1}, core.Keep_Tab{tab_id = ed}, core.Diff_File{tab_id = ed}, core.Set_Wrap{tab_id = ed}, core.Open_File{path = "notes.txt"}, core.Markdown_Open{path = "README.md"}, core.Create_File{path = "x"}, core.Rename_Path{from = "notes.txt", to = "y"}, core.Delete_Path{path = "notes.txt"}, core.Close_Tab{tab_id = ed}, core.Send_Text{tab_id = ed}}) {
			testing.expectf(t, !core.caller_may(c, cmd), "an agent tab may not send %s", core.command_type(cmd))
		}
	}
	// the user and scripts: the session on screen, in front (as open_file)
	r = core.run_command(core.Show_File{path = "notes.txt"}, {kind = .Script})
	testing.expectf(t, r.ok, "a script shows a file: %s", r.error)
	s, _, _ := core.find_tab(r.created_id)
	testing.expect(t, s != nil && s.id == b, "in the session on screen")
	testing.expect_value(t, core.find_session(b).active_tab, r.created_id)
	// Home's agent (control, bound to Home): must name a session; behind the user's view there
	atlas := core.Caller{kind = .Control, tab_id = sf_tab(home, 0)}
	r = core.run_command(core.Show_File{path = fmt.tprintf("%s/README.md", sa.cwd)}, atlas)
	testing.expectf(t, !r.ok && strings.contains(r.error, "session"), "Home has no tabs to show it in: %s", r.error)
	active := core.find_session(a).active_tab
	r = core.run_command(core.Show_File{path = fmt.tprintf("%s/README.md", sa.cwd), session = a}, atlas)
	testing.expectf(t, r.ok, "Atlas names a session: %s", r.error)
	s, _, _ = core.find_tab(r.created_id)
	testing.expect(t, s != nil && s.id == a, "in the session it named")
	testing.expect_value(t, core.find_session(a).active_tab, active)
	testing.expect_value(t, state.current_session, b)
}

// The wire: show_file parses, and lists for a pi tab and a Claude tab.
@(test)
show_file_wire :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	cmd, err := core.parse_command(`{"type":"show_file","path":"docs/a.md","anchor":"setup","line":4,"session":9}`)
	testing.expect_value(t, err, "")
	sf, is := cmd.(core.Show_File)
	testing.expect(t, is, "a Show_File")
	testing.expect_value(t, sf.path, "docs/a.md")
	testing.expect_value(t, sf.anchor, "setup")
	testing.expect_value(t, sf.line, 4)
	testing.expect_value(t, sf.session, u64(9))
	testing.expect_value(t, core.command_type(cmd), "show_file")
	b := strings.builder_make(context.temp_allocator)
	core.write_command(&b, cmd)
	out := strings.to_string(b)
	testing.expectf(t, strings.contains(out, `"path":"docs/a.md"`) && strings.contains(out, `"line":4`) && strings.contains(out, `"anchor":"setup"`), "written back: %s", out)
	c2 := core.command_clone(cmd, context.allocator)
	testing.expect_value(t, c2.(core.Show_File).path, "docs/a.md")
	core.command_free(c2, context.allocator)
	spec := core.command_spec("show_file")
	testing.expect(t, spec != nil && spec.who == .Own_Session, "own session, as browser_open")
}

// ---- review fixes ----

@(private = "file")
sf_refused :: proc(t: ^testing.T, r: core.Result, code: string, loc := #caller_location) {
	testing.expectf(t, !r.ok && core.json_path(r.data, "code") == code, "refused %s: %s %s", code, r.error, r.data, loc = loc)
	testing.expectf(t, !strings.has_prefix(core.json_path(r.data, "hint"), "<"), "with a hint: %s", r.data, loc = loc)
}

// Paths that can freeze the UI (network and removable volumes, iCloud files not downloaded) and
// devices (/dev/fd/N too) are refused before anything reads them, as given and as resolved.
@(test)
show_file_slow_paths_and_devices :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir, _ := sf_reset(t)
	defer sf_done(dir)
	pi := core.Caller{kind = .Panel, tab_id = sf_tab(a, 0)}
	cwd := core.find_session(a).cwd
	for p in ([]string{"/net/host/x.md", "/Volumes/USB/x.md", "/System/Volumes/Data/net/host/x.md"}) {
		sf_refused(t, core.run_command(core.Show_File{path = p}, pi), "slow_path")
	}
	// a link to /Volumes: refused by its real path
	posix.symlink("/Volumes", strings.clone_to_cstring(fmt.tprintf("%s/vol", cwd), context.temp_allocator))
	sf_refused(t, core.run_command(core.Show_File{path = "vol/zz-none/x.md"}, pi), "slow_path")
	// an iCloud file not downloaded (dataless): refused, never read
	saved := core.show_file_flags
	defer core.show_file_flags = saved
	core.show_file_flags = proc(path: string) -> u32 {return strings.has_suffix(path, "notes.txt") ? core.SF_DATALESS : 0}
	sf_refused(t, core.run_command(core.Show_File{path = "notes.txt"}, pi), "not_downloaded")
	core.show_file_flags = saved
	// devices: /dev/fd/N, /dev/null, and a link to one
	for p in ([]string{"/dev/fd/0", "/dev/null", "/dev/../dev/zero"}) do sf_refused(t, core.run_command(core.Show_File{path = p}, pi), "device")
	posix.symlink("/dev/null", strings.clone_to_cstring(fmt.tprintf("%s/null.txt", cwd), context.temp_allocator))
	sf_refused(t, core.run_command(core.Show_File{path = "null.txt"}, pi), "device")
	testing.expect_value(t, sf_count(a), 3)
}

// An agent never moves the user's view: a tab it did not open, or the tab the user looks at, keeps
// its caret and scroll (already_open, nothing moved).
@(test)
show_file_already_open_never_moves_the_user :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, _, dir, _ := sf_reset(t)
	defer sf_done(dir)
	pi := core.Caller{kind = .Panel, tab_id = sf_tab(a, 0)}
	claude := core.Caller{kind = .Panel, tab_id = sf_tab(a, 1), claude = true}
	cwd := core.find_session(a).cwd
	// the user's own tab (opened by the user, on screen in a): untouched
	ru := core.run_command(core.Open_File{path = fmt.tprintf("%s/notes.txt", cwd), session = a, line = 2}, {kind = .Script})
	testing.expect(t, ru.ok, ru.error)
	r := core.run_command(core.Show_File{path = "notes.txt", line = 4}, pi)
	testing.expect(t, r.ok && r.created_id == ru.created_id, "the same tab")
	testing.expect_value(t, core.json_path(r.data, "already_open"), "true")
	e := editor_of(ru.created_id)
	l, _ := ed_line_col(e, e.cursor)
	testing.expect_value(t, l, 2)
	// a tab the pi opened, which another agent (Claude) asks for: untouched
	rm := core.run_command(core.Show_File{path = "README.md"}, pi)
	testing.expect(t, rm.ok, rm.error)
	r = core.run_command(core.Show_File{path = "README.md", anchor = "setup"}, claude)
	testing.expect(t, r.ok && r.created_id == rm.created_id, "the same tab")
	testing.expect_value(t, md_view_of(rm.created_id).want, "")
	// its own tab, while the user looks at it: untouched
	core.run_command(core.Focus_Tab{tab_id = rm.created_id}, {kind = .Script})
	testing.expect_value(t, state.current_session, a)
	r = core.run_command(core.Show_File{path = "README.md", anchor = "setup"}, pi)
	testing.expect(t, r.ok && core.json_path(r.data, "already_open") == "true", r.error)
	testing.expect_value(t, md_view_of(rm.created_id).want, "")
	// its own tab, not on screen: scrolled as asked
	core.run_command(core.Focus_Session{session = b}, {kind = .Script})
	r = core.run_command(core.Show_File{path = "README.md", anchor = "setup"}, pi)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, md_view_of(rm.created_id).want, "setup")
}

// Secrets an agent never shows, by name and by real path (a link to one too); the user and scripts
// are unaffected.
@(test)
show_file_secrets_refused_for_agents :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir, _ := sf_reset(t)
	defer sf_done(dir)
	pi := core.Caller{kind = .Panel, tab_id = sf_tab(a, 0)}
	cwd := core.find_session(a).cwd
	home := fmt.aprintf("%s/home", core.fs_real(dir))
	saved_home := os.get_env("HOME", context.temp_allocator)
	posix.setenv("HOME", strings.clone_to_cstring(home, context.temp_allocator), true)
	defer posix.setenv("HOME", strings.clone_to_cstring(saved_home, context.temp_allocator), true)
	w :: proc(p: string) {
		os.make_directory_all(filepath.dir(p))
		_ = os.write_entire_file(p, transmute([]u8)string("x\n"))
	}
	secrets := []string {
		fmt.tprintf("%s/.ssh/id_ed25519", home), fmt.tprintf("%s/.ssh/config", home), fmt.tprintf("%s/.aws/credentials", home),
		fmt.tprintf("%s/.gnupg/pubring.kbx", home), fmt.tprintf("%s/.netrc", home), fmt.tprintf("%s/.npmrc", home),
		fmt.tprintf("%s/.config/gh/hosts.yml", home), fmt.tprintf("%s/Library/Keychains/login.keychain-db", home),
		fmt.tprintf("%s/.envrc", cwd), fmt.tprintf("%s/server.pem", cwd), fmt.tprintf("%s/tls.key", cwd), fmt.tprintf("%s/id_rsa", cwd),
	}
	for p in secrets {
		w(p)
		sf_refused(t, core.run_command(core.Show_File{path = p}, pi), "secret")
	}
	// a harmless-looking link to one: refused by its real path
	posix.symlink(strings.clone_to_cstring(fmt.tprintf("%s/.ssh/config", home), context.temp_allocator), strings.clone_to_cstring(fmt.tprintf("%s/ssh-notes.txt", cwd), context.temp_allocator))
	sf_refused(t, core.run_command(core.Show_File{path = "ssh-notes.txt"}, pi), "secret")
	sf_refused(t, core.run_command(core.Show_File{path = fmt.tprintf("%s/.ssh/config", home), session = a}, {kind = .Control}), "secret")
	testing.expect_value(t, sf_count(a), 3)
	// the user's and scripts' own: unaffected
	r := core.run_command(core.Show_File{path = fmt.tprintf("%s/server.pem", cwd)}, {kind = .Script})
	testing.expectf(t, r.ok, "a script shows it: %s", r.error)
	// names that only look alike: shown
	w(fmt.tprintf("%s/keys.md", cwd))
	testing.expect(t, core.run_command(core.Show_File{path = "keys.md"}, pi).ok, "keys.md")
}

// At most SHOW_FILE_MAX_TABS tabs agents opened per session; a file already open still answers.
@(test)
show_file_caps_agent_tabs :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir, _ := sf_reset(t)
	defer sf_done(dir)
	pi := core.Caller{kind = .Panel, tab_id = sf_tab(a, 0)}
	cwd := core.find_session(a).cwd
	for i in 0 ..< core.SHOW_FILE_MAX_TABS + 1 {
		_ = os.write_entire_file(fmt.tprintf("%s/f%d.txt", cwd, i), transmute([]u8)string("x\n"))
	}
	for i in 0 ..< core.SHOW_FILE_MAX_TABS {
		r := core.run_command(core.Show_File{path = fmt.tprintf("f%d.txt", i)}, pi)
		testing.expectf(t, r.ok, "tab %d: %s", i, r.error)
	}
	sf_refused(t, core.run_command(core.Show_File{path = fmt.tprintf("f%d.txt", core.SHOW_FILE_MAX_TABS)}, pi), "too_many_tabs")
	testing.expect(t, core.run_command(core.Show_File{path = "f0.txt"}, pi).ok, "already open: still fine")
	testing.expect_value(t, sf_count(a), 3 + core.SHOW_FILE_MAX_TABS)
}

// The pre-check reads one chunk, never the whole file (editor_new reads it once after).
@(test)
show_file_peek_reads_little :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir, _ := sf_reset(t)
	defer sf_done(dir)
	cwd := core.find_session(a).cwd
	big := strings.repeat("text line\n", 200_000, context.temp_allocator) // ~2 MB
	p := fmt.tprintf("%s/big.txt", cwd)
	_ = os.write_entire_file(p, transmute([]u8)big)
	@(static) reads: int
	reads = 0
	saved := core.disk_read_chunk
	defer core.disk_read_chunk = saved
	core.disk_read_chunk = proc(f: ^os.File, b: []u8) -> (int, os.Error) {reads += 1; return os.read(f, b)}
	testing.expect_value(t, core.show_file_peek(p), "")
	testing.expect_value(t, reads, 1)
	bin := fmt.tprintf("%s/b.bin", cwd)
	_ = os.write_entire_file(bin, transmute([]u8)string("\x7fELF\x00\x01"))
	testing.expect(t, strings.has_prefix(core.show_file_peek(bin), "Binary"), "binary from the first chunk")
}
