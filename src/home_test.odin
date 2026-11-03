package main

// Home, self-protection, send_text rules, list_commands and close_session
// (`./build.sh test`). Same rules as core_test.odin: shared global State, one
// thread, harmless processes (/bin/sh, `sleep`); the socket in a temp dir.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
H_UI :: Caller{kind = .UI}
@(private = "file")
H_SCRIPT :: Caller{kind = .Script}

@(private = "file")
h_dir: string

@(private = "file")
h_reset :: proc(t: ^testing.T, socket := false) {
	context.allocator = runtime.heap_allocator()
	for _, x in terms {
		term_free(x)
		free(x)
	}
	clear(&terms)
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT},
	}
	persist = {}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	h_dir = fmt.aprintf("%s/pd-home-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory_all(h_dir)
	home_root = h_dir
	if socket {
		os.set_env("PI_DESK_RUNTIME_DIR", fmt.tprintf("%s/run", h_dir))
		rdir, ok := sock_runtime_dir(context.temp_allocator)
		testing.expect(t, ok, "runtime dir")
		testing.expect(t, socket_start(rdir), "socket_start")
	}
}

@(private = "file")
h_stop :: proc() {
	socket_stop(proc() {inbox_drain()})
	home_root = ""
}

// A tiny socket client (the test thread pumps the inbox while it waits).
@(private = "file")
Hc :: struct {
	fd:     Sock_Fd,
	buf:    [dynamic]u8,
	closed: bool,
	lines:  [dynamic]string, // read while looking for a reply
}

@(private = "file")
hc_recv :: proc(c: ^Hc, ms := 3000) -> string {
	start := time.tick_now()
	for {
		if i := strings.index_byte(string(c.buf[:]), '\n'); i >= 0 {
			line := strings.clone(string(c.buf[:i]))
			remove_range(&c.buf, 0, i + 1)
			return line
		}
		if c.closed || time.tick_since(start) > time.Duration(ms) * time.Millisecond do return ""
		inbox_drain()
		if sock_wait_readable(c.fd, 5) {
			chunk: [16 * 1024]u8
			n := sock_read(c.fd, chunk[:])
			if n <= 0 do c.closed = true
			else do append(&c.buf, ..chunk[:n])
		}
	}
}

@(private = "file")
hc_req :: proc(c: ^Hc, id, line: string) -> string {
	sock_write_all(c.fd, transmute([]u8)strings.concatenate({line, "\n"}, context.temp_allocator))
	for {
		l := hc_recv(c)
		if l == "" do return ""
		if json_path(l, "id") == id do return l
		append(&c.lines, l)
	}
}

@(private = "file")
hc_cmd :: proc(c: ^Hc, cmd: string) -> string {
	return hc_req(c, "q", fmt.tprintf(`{{"id":"q","v":1,"type":"command","command":%s}}`, cmd))
}

@(private = "file")
hc_hello :: proc(token: string) -> (^Hc, string) {
	fd, ok := sock_connect(socket_path())
	if !ok do return nil, ""
	c := new(Hc)
	c.fd = fd
	return c, hc_req(c, "h", fmt.tprintf(`{{"id":"h","v":1,"type":"hello","token":"%s"}}`, token))
}

@(private = "file")
hc_close :: proc(c: ^Hc) {
	sock_close(c.fd)
	delete(c.buf)
	delete(c.lines)
	free(c)
}

// Opens Home with a fake pi that writes its environment tokens and arguments
// to files; returns Home's tab and its env tokens (bridge and control).
@(private = "file")
h_open_home :: proc(t: ^testing.T) -> (tab: u64, panel_tok, control_tok: string) {
	os.set_env("PI_DESK_CMD", fmt.tprintf(`printf %%s "$PI_DESK_TOKEN" > %s/ptok; printf %%s "$PI_DESK_CONTROL_TOKEN" > %s/ctok; printf '%%s\n' "$@" > %s/args; exec sleep 30`, h_dir, h_dir, h_dir))
	r := run_command(Set_Home{open = true}, H_UI)
	testing.expect(t, r.ok, r.error)
	tab = r.created_id
	testing.expect_value(t, tab, home_tab().id)
	for _ in 0 ..< 200 {
		p, e1 := os.read_entire_file(fmt.tprintf("%s/ptok", h_dir), context.temp_allocator)
		c, e2 := os.read_entire_file(fmt.tprintf("%s/ctok", h_dir), context.temp_allocator)
		if e1 == nil && e2 == nil && len(c) == 64 do return tab, strings.clone(string(p)), strings.clone(string(c))
		time.sleep(20 * time.Millisecond)
	}
	testing.fail_now(t, "no tokens from Home's pi")
}

// A project session with a shell tab: (session, pi tab, shell tab).
@(private = "file")
h_session :: proc(t: ^testing.T) -> (sess, pitab, shell: u64) {
	os.set_env("PI_DESK_CMD", "sleep 30")
	if state.selected_project == 0 do run_command(Add_Project{cwd = "/tmp"}, H_UI)
	sess = run_command(New_Chat{project_id = state.selected_project}, H_UI).created_id
	testing.expect(t, sess != 0, "new chat")
	pitab = find_session(sess).tabs[0].id
	shell = run_command(New_Shell_Tab{session = sess}, H_UI).created_id
	testing.expect(t, shell != 0, "shell tab")
	return
}

@(test)
home_control_token_bound_to_its_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t, socket = true)
	defer h_stop()
	tab, ptok, ctok := h_open_home(t)
	testing.expect_value(t, len(ptok), 64) // its bridge reports its status (pi-kit's desk-bridge)
	testing.expect(t, state.home_open)
	hs := home_session()
	testing.expect(t, hs != nil && hs.home && hs.project_id == 0)
	testing.expect_value(t, hs.session_dir, fmt.tprintf("%s/home", h_dir))
	testing.expect(t, os.is_dir(hs.session_dir))
	// a new Home session: pi's TUI gets --session-dir, --session-id and Atlas's prompt
	args, _ := os.read_entire_file(fmt.tprintf("%s/args", h_dir), context.temp_allocator)
	testing.expect(t, strings.contains(string(args), fmt.tprintf("--session-dir\n%s/home\n--session-id\n%s\n--append-system-prompt\n%s/atlas/ATLAS.md\n", h_dir, hs.pi_session_id, h_dir)), string(args))
	testing.expect(t, !strings.contains(string(args), "--mode"), string(args))
	// the bridge token: a panel caller bound to Home's tab
	pc, pr := hc_hello(ptok)
	testing.expect_value(t, json_path(pr, "result.data.caller"), "panel")
	testing.expect_value(t, json_path(pr, "result.data.tab_id"), fmt.tprint(tab))
	hc_close(pc)

	c, r := hc_hello(ctok)
	testing.expect_value(t, json_path(r, "result.data.caller"), "control")
	testing.expect_value(t, json_path(r, "result.data.tab_id"), fmt.tprint(tab))
	testing.expect_value(t, json_path(r, "result.data.capabilities.0"), "commands")
	re := json_path(r, "result.data.reconnect_token")
	testing.expect_value(t, len(re), 64)
	// single use: the env token is gone, the reconnect token is the same caller
	c2, r2 := hc_hello(ctok)
	testing.expect_value(t, json_path(r2, "result.error"), "unknown token")
	c3, r3 := hc_hello(re)
	testing.expect_value(t, json_path(r3, "result.data.caller"), "control")
	testing.expect_value(t, json_path(r3, "result.data.tab_id"), fmt.tprint(tab))
	// state: Home is marked, has no project, and the drawer's field has the keyboard
	st := json_path(hc_cmd(c, `{"type":"get_state"}`), "result.ok")
	testing.expect_value(t, st, "true")
	testing.expect_value(t, json_path(state_json(), "home.tab_id"), fmt.tprint(tab))
	testing.expect_value(t, json_path(state_json(), "home.open"), "true")
	testing.expect_value(t, json_path(state_json(), "focus.id"), "agent_input")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.home"), "true")
	// the control token dies with Home's tab
	run_command(Tab_Exited{tab_id = tab})
	c4, r4 := hc_hello(re)
	testing.expect_value(t, json_path(r4, "result.error"), "unknown token")
	// opening again starts Home again (resuming its session) with new tokens
	os.remove(fmt.tprintf("%s/ctok", h_dir))
	tab2, _, ctok2 := h_open_home(t)
	testing.expect_value(t, tab2, tab)
	testing.expect(t, ctok2 != ctok)
	testing.expect(t, home_tab().status == .Running)
	for x in ([]^Hc{c, c2, c3, c4}) do hc_close(x)
}

@(test)
home_self_protection :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t, socket = true)
	defer h_stop()
	_, pitab, shell := h_session(t)
	tab, _, ctok := h_open_home(t)
	c, _ := hc_hello(ctok)
	defer hc_close(c)
	refused :: proc(t: ^testing.T, c: ^Hc, cmd, want: string, loc := #caller_location) {
		r := hc_cmd(c, cmd)
		testing.expect_value(t, json_path(r, "result.ok"), "false", loc = loc)
		testing.expect_value(t, json_path(r, "result.error"), want, loc = loc)
	}
	refused(t, c, fmt.tprintf(`{{"type":"close_tab","tab_id":%d}}`, tab), "a session's pi tab cannot be closed")
	refused(t, c, fmt.tprintf(`{{"type":"pi_prompt","tab_id":%d,"text":"hi"}}`, tab), "a caller cannot act on its own tab")
	refused(t, c, fmt.tprintf(`{{"type":"pi_reload","tab_id":%d}}`, tab), "a caller cannot act on its own tab")
	refused(t, c, fmt.tprintf(`{{"type":"pi_wait_idle","tab_id":%d}}`, tab), "a caller cannot act on its own tab")
	refused(t, c, fmt.tprintf(`{{"type":"send_text","tab_id":%d,"text":"x"}}`, tab), "a caller cannot act on its own tab")
	refused(t, c, fmt.tprintf(`{{"type":"close_session","session":%d}}`, state.home), "Home cannot be closed")
	refused(t, c, fmt.tprintf(`{{"type":"new_shell_tab","session":%d}}`, state.home), "Home has only its pi tab")
	refused(t, c, fmt.tprintf(`{{"type":"focus_tab","tab_id":%d}}`, tab), HOME_NOT_A_SESSION)
	// Home may act on other tabs
	r := hc_cmd(c, fmt.tprintf(`{{"type":"send_text","tab_id":%d,"text":"echo hi\n"}}`, shell))
	testing.expect_value(t, json_path(r, "result.ok"), "true")

	// any caller bound to a tab: nothing in its own session either
	bound := Caller{kind = .Control, tab_id = pitab}
	s, _, _ := find_tab(pitab)
	testing.expect_value(t, run_command(Close_Tab{tab_id = shell}, bound).error, "a caller cannot close its own tab")
	testing.expect_value(t, run_command(Send_Text{tab_id = shell, text = "x"}, bound).error, "a caller cannot act on its own tab")
	testing.expect_value(t, run_command(Close_Session{session = s.id}, bound).error, "a caller cannot close its own session")
	testing.expect_value(t, run_command(Pi_Prompt{tab_id = pitab, text = "x"}, bound).error, "a caller cannot act on its own tab")

	// own events: Home's control connection never sees its own tab's
	sub := hc_req(c, "s", `{"id":"s","v":1,"type":"subscribe"}`)
	testing.expect_value(t, json_path(sub, "result.ok"), "true")
	run_command(Pi_Status_Update{tab_id = tab, agent = .Working}, H_SCRIPT) // Home's own status
	run_command(Pi_Status_Update{tab_id = tab, agent = .Idle}, {kind = .Internal})
	run_command(Pi_Status_Update{tab_id = pitab, agent = .Working}, H_SCRIPT) // another tab: seen
	got_other, got_own := false, false
	for _ in 0 ..< 10 {
		l := hc_recv(c, 500)
		if l == "" do break
		if json_path(l, "event") != "command" do continue
		id := json_path(l, "command.tab_id")
		if id == fmt.tprint(pitab) do got_other = true
		if id == fmt.tprint(tab) do got_own = true
	}
	for l in c.lines do if json_path(l, "command.tab_id") == fmt.tprint(tab) do got_own = true
	testing.expect(t, got_other, "an event about another tab")
	testing.expect(t, !got_own, "no events about Home's own tab")
	// the filter itself
	testing.expect(t, !event_visible_to(Command_Event{caller = H_SCRIPT, command = Tab_Exited{tab_id = tab}}, {kind = .Control, tab_id = tab}))
	testing.expect(t, event_visible_to(Command_Event{caller = H_SCRIPT, command = Tab_Exited{tab_id = shell}}, {kind = .Control, tab_id = tab}))
	testing.expect(t, event_visible_to(Command_Event{caller = H_SCRIPT, command = Tab_Exited{tab_id = tab}}, {kind = .Control}))
}

@(test)
send_text_rules :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	sess, pitab, shell := h_session(t)
	ctl := Caller{kind = .Control}
	testing.expect_value(t, run_command(Send_Text{tab_id = pitab, text = "x"}, ctl).error, "send prompts to a pi tab with pi_prompt, not send_text")
	testing.expect(t, run_command(Send_Text{tab_id = shell, text = "true\n"}, ctl).ok, "control -> shell")
	// scripts and the user are unchanged
	testing.expect(t, run_command(Send_Text{tab_id = pitab, text = "x"}, H_SCRIPT).ok, "script -> pi")
	testing.expect(t, run_command(Send_Text{tab_id = pitab, text = "x"}, H_UI).ok, "ui -> pi")
	// a session whose pi waits for the user is the user's
	run_command(Pi_Status_Update{tab_id = pitab, agent = .Working, waiting = true}, H_SCRIPT)
	testing.expect_value(t, run_command(Send_Text{tab_id = shell, text = "x"}, ctl).error, "pi in this session is waiting for the user")
	testing.expect(t, run_command(Send_Text{tab_id = shell, text = "true\n"}, H_SCRIPT).ok, "script -> shell while waiting")
	_ = sess
}

@(test)
list_commands_per_caller :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	types :: proc(caller: Caller) -> map[string]string {
		r := run_command(List_Commands{}, caller)
		m := make(map[string]string, context.temp_allocator)
		if !r.ok do return m
		count, _ := strconv.parse_int(json_path(r.data, "commands.#"))
		for i in 0 ..< count {
			ty := json_path(r.data, fmt.tprintf("commands.%d.type", i))
			m[ty] = fmt.tprintf("%s|%s|%s|%s", json_path(r.data, fmt.tprintf("commands.%d.args", i)), json_path(r.data, fmt.tprintf("commands.%d.confirm_class", i)), json_path(r.data, fmt.tprintf("commands.%d.long_running", i)), json_path(r.data, fmt.tprintf("commands.%d.does", i)))
		}
		return m
	}
	ctl := types({kind = .Control, tab_id = 7})
	for want in ([]string{"get_state", "list_commands", "add_project", "new_chat", "close_tab", "close_session", "send_text", "pi_prompt", "pi_reload", "set_home", "quit", "set_theme"}) {
		testing.expectf(t, want in ctl, "control lists %s", want)
	}
	for not in ([]string{"set_confirm_policy", "set_close_confirm", "panel.set", "panel.remove", "pi.status", "pi.session", "tab_exited", "restore_session", "bridge_done", "rescan_done"}) {
		testing.expectf(t, !(not in ctl), "control does not list %s", not)
	}
	testing.expect(t, strings.has_prefix(ctl["close_session"], "session, confirm?, comments?|tab_close|<missing>|"), ctl["close_session"])
	testing.expect(t, strings.has_prefix(ctl["pi_prompt"], "tab_id, text, images?|<missing>|true|"), ctl["pi_prompt"])
	testing.expect(t, strings.has_prefix(ctl["pi_reload"], "tab_id, confirm?|session_restart|true|"), ctl["pi_reload"])
	testing.expect(t, strings.has_prefix(ctl["get_state"], "<missing>|<missing>|<missing>|"), ctl["get_state"])
	// a pi tab: queries, its own reports, and its own session's browser tabs (browser_nav.odin)
	pan := types({kind = .Panel, tab_id = 7})
	testing.expect_value(t, len(pan), 30)
	for want in ([]string{"get_state", "list_commands", "list_worktrees", "job_list", "job_runs", "pi.session", "pi.status", "panel.set", "panel.remove", "pi.attached", "browser_open", "browser_navigate", "browser_back", "browser_forward", "browser_reload", "browser_stop", "browser_tabs", "browser_read", "browser_screenshot", "browser_wait", "browser_console", "browser_network", "browser_comments", "browser_click", "browser_type", "browser_press", "browser_scroll", "browser_select", "browser_hover", "browser_upload"}) do testing.expectf(t, want in pan, "panel lists %s", want)
	testing.expect(t, !("browser_agent_stop" in pan), "Stop is the user's")
	testing.expect(t, !("browser_agent_take_over" in pan) && !("browser_upload_answer" in pan), "Take over and the upload bar are the user's")
	// the user: user-only settings, not bridge-only or internal ones
	ui := types(H_UI)
	testing.expect(t, "set_confirm_policy" in ui && "set_close_confirm" in ui && !("panel.set" in ui) && !("tab_exited" in ui))
	scr := types(H_SCRIPT)
	testing.expect(t, "pi.status" in scr && !("set_confirm_policy" in scr) && !("panel.set" in scr))
	// one table: every command type has exactly one row, and parses by that name
	testing.expect_value(t, len(COMMAND_SPECS), len(type_info_of(Command).variant.(runtime.Type_Info_Named).base.variant.(runtime.Type_Info_Union).variants))
	seen := make(map[string]bool, context.temp_allocator)
	for s in COMMAND_SPECS {
		testing.expectf(t, !seen[s.type], "one row per type: %s", s.type)
		seen[s.type] = true
		_, err := parse_command(fmt.tprintf(`{{"type":"%s"}}`, s.type), context.temp_allocator)
		unknown := strings.has_prefix(err, "unknown command")
		testing.expectf(t, unknown == (s.who == .Internal), "%s parses: %s", s.type, err)
	}
	for c in ([]Command{Tab_Exited{}, Rescan_Done{}, Bridge_Done{}, Restore_Session{}}) do testing.expectf(t, command_spec(command_type(c)) != nil, "row for %s", command_type(c))
	// and over the wire
	r := run_command(List_Commands{}, {kind = .Control})
	testing.expect(t, strings.has_prefix(r.data, `{"commands":[{"type":"get_state","does":`), r.data)
}

@(test)
close_session_confirms_and_forgets :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	a, apt, _ := h_session(t)
	b, bpt, bsh := h_session(t)
	testing.expect_value(t, state.current_session, b)
	// pi status unknown (no bridge): closing asks; scripts get no token
	r := run_command(Close_Session{session = b}, H_SCRIPT)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect(t, r.confirm_by_user && r.confirm_token == "")
	testing.expect_value(t, len(state.pending_confirmations), 1)
	testing.expect_value(t, json_path(state_json(), "pending_confirmations.0.class"), "tab_close")
	testing.expect_value(t, json_path(state_json(), "pending_confirmations.0.command.type"), "close_session")
	testing.expect(t, find_session(b) != nil, "nothing closed yet")
	testing.expect_value(t, run_command(Close_Session{session = b, confirm = "nope"}, H_SCRIPT).error, "unknown or expired confirmation token")
	// the user confirms it (as the confirmation bar does)
	tok := state.pending_confirmations[0].token
	r = run_command(Close_Session{session = b, confirm = tok}, H_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, find_session(b) == nil, "closed")
	testing.expect(t, term_of(bpt) == nil && term_of(bsh) == nil, "its terminals stopped")
	testing.expect_value(t, len(state.pending_confirmations), 0)
	testing.expect_value(t, state.current_session, a) // the other open session
	// an idle session closes without asking
	run_command(Pi_Status_Update{tab_id = apt, agent = .Idle}, H_SCRIPT)
	r = run_command(Close_Session{session = a}, {kind = .Control})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(state.open_sessions), 0)
	testing.expect_value(t, state.current_session, 0)
	testing.expect_value(t, run_command(Close_Session{session = a}, H_UI).error, "no such session")
	// a pending close_session goes when the session goes another way
	c, _, _ := h_session(t)
	run_command(Close_Session{session = c}, H_SCRIPT)
	testing.expect_value(t, len(state.pending_confirmations), 1)
	run_command(Close_Session{session = c, confirm = state.pending_confirmations[0].token}, H_UI)
	testing.expect_value(t, len(state.pending_confirmations), 0)
}

// A closed session leaves the saved workspace; Home is saved by its pi
// session id only and restored not started.
@(test)
close_session_and_home_persist :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	proj := fmt.aprintf("%s/proj", h_dir)
	os.make_directory_all(proj)
	home := fmt.aprintf("%s/userhome", h_dir)
	store := fmt.tprintf("%s/.pi/agent/sessions/--x--", home)
	os.make_directory_all(store)
	for id, i in ([]string{"aaaa-1", "bbbb-2"}) {
		_ = os.write_entire_file(fmt.tprintf("%s/2026-10-30T10-00-0%d-000Z_%s.jsonl", store, i, id), transmute([]u8)fmt.tprintf(`{{"type":"session","version":3,"id":"%s","cwd":"%s"}}`+"\n", id, proj))
	}
	old_home := os.get_env("HOME", context.temp_allocator)
	os.set_env("HOME", home)
	defer os.set_env("HOME", old_home)
	rescan_now()
	p := state.projects[0].id
	run_command(Select_Project{project_id = p}, H_UI)
	s1 := run_command(Open_Session_Cmd{project_id = p, pi_session_id = "aaaa-1"}, H_UI).created_id
	s2 := run_command(Open_Session_Cmd{project_id = p, pi_session_id = "bbbb-2"}, H_UI).created_id
	testing.expect(t, s1 != 0 && s2 != 0)
	testing.expect(t, run_command(Set_Home{open = true}, H_UI).ok)
	hid := strings.clone(home_session().pi_session_id)
	testing.expect_value(t, home_session().cwd, home) // the user's home folder
	text := strings.clone(workspace_json())
	testing.expect(t, strings.contains(text, "aaaa-1") && strings.contains(text, "bbbb-2"), text)
	testing.expect(t, strings.contains(text, fmt.tprintf(`"home":{{"pi_session_id":"%s"}}`, hid)), text)
	testing.expect_value(t, strings.count(text, `"pi_session_id"`), 3) // Home is not an open session there
	testing.expect(t, strings.contains(text, `"drawer_open":true`), text) // reopens (and starts) at launch
	run_command(Set_Home{open = false}, H_UI)
	run_command(Pi_Status_Update{tab_id = find_session(s2).tabs[0].id, agent = .Idle}, H_SCRIPT)
	testing.expect(t, run_command(Close_Session{session = s2}, H_UI).ok)
	text = strings.clone(workspace_json())
	testing.expect(t, !strings.contains(text, "bbbb-2"), text)

	// relaunch: Home is back, not started, closed; opening starts it with its id
	h_reset(t)
	os.set_env("HOME", home)
	rescan_now()
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect_value(t, len(state.open_sessions), 2)
	hs := home_session()
	testing.expect(t, hs != nil && hs.home && hs.restored)
	testing.expect_value(t, hs.pi_session_id, hid)
	testing.expect(t, hs.tabs[0].status == .Not_Started && !state.home_open)
	testing.expect_value(t, json_path(state_json(), "open_sessions.1.tabs.0.status"), "not_started")
	// Home is never the current session and is not focusable as one
	testing.expect_value(t, run_command(Focus_Session{session = hs.id}, H_UI).error, HOME_NOT_A_SESSION)
	os.set_env("PI_DESK_CMD", fmt.tprintf(`printf '%%s\n' "$@" > %s/args; exec sleep 30`, h_dir))
	testing.expect(t, run_command(Set_Home{open = true}, H_UI).ok)
	for _ in 0 ..< 200 {
		if os.exists(fmt.tprintf("%s/args", h_dir)) do break
		time.sleep(20 * time.Millisecond)
	}
	time.sleep(50 * time.Millisecond)
	args, _ := os.read_entire_file(fmt.tprintf("%s/args", h_dir), context.temp_allocator)
	testing.expect(t, strings.contains(string(args), fmt.tprintf("--session-id\n%s", hid)), string(args))
	// set_home false hides the pane; Home keeps running
	testing.expect(t, run_command(Set_Home{open = false}, H_UI).ok)
	testing.expect(t, !state.home_open && home_tab().status == .Running)
}

// ---- review round 1 ----

// A shell tab whose foreground program is not the shell (sleep).
@(private = "file")
h_busy_shell :: proc(t: ^testing.T, sess: u64) -> u64 {
	sh := run_command(New_Shell_Tab{session = sess}, H_UI).created_id
	run_command(Send_Text{tab_id = sh, text = "sleep 30\n"}, H_SCRIPT)
	for _ in 0 ..< 200 {
		if x := term_of(sh); x != nil && pty_foreground_busy(&x.pty) do return sh
		time.sleep(10 * time.Millisecond)
	}
	testing.fail_now(t, "the shell never ran sleep")
}

// 1. control types only at a shell prompt, never into a running program
@(test)
control_send_text_only_at_a_prompt :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	sess, _, _ := h_session(t)
	sh := h_busy_shell(t, sess)
	testing.expect_value(t, run_command(Send_Text{tab_id = sh, text = "y\n"}, {kind = .Control}).error, "a program is running in this tab; control callers type only at a shell prompt")
	testing.expect(t, run_command(Send_Text{tab_id = sh, text = "x"}, H_SCRIPT).ok, "scripts unchanged")
}

// 2. the bar says who asks and what
@(test)
confirmation_says_who_and_what :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	sess, _, _ := h_session(t)
	pname := project_name(find_project(state.selected_project)^)
	sh := h_busy_shell(t, sess)
	testing.expect(t, run_command(Set_Home{open = true}, H_UI).ok)
	home := Caller{kind = .Control, tab_id = home_tab().id}
	r := run_command(Close_Tab{tab_id = sh}, home)
	testing.expect_value(t, r.confirm_summary, fmt.tprintf("Atlas asks: close %q in %s · Untitled session? Its process is still running.", "shell 2", pname))
	r = run_command(Close_Tab{tab_id = sh}, H_SCRIPT)
	testing.expect(t, strings.has_prefix(r.confirm_summary, "A script asks: close "), r.confirm_summary)
	r = run_command(Quit{}, home)
	testing.expect_value(t, r.confirm_summary, "Atlas asks: quit pi-desk? Running sessions will be stopped.")
	r = run_command(Quit{}, H_UI)
	testing.expect_value(t, r.confirm_summary, "Quit pi-desk? Running sessions will be stopped.")
	testing.expect_value(t, json_path(state_json(), "pending_confirmations.0.summary"), fmt.tprintf("Atlas asks: close %q in %s · Untitled session? Its process is still running.", "shell 2", pname))
}

// 2. an open session's title comes from its file even when its project is not selected
@(test)
open_session_title_any_project :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	home := fmt.aprintf("%s/userhome", h_dir)
	for p, i in ([]string{"a", "b"}) {
		store := fmt.tprintf("%s/.pi/agent/sessions/--%s--", home, p)
		os.make_directory_all(store)
		os.make_directory_all(fmt.tprintf("%s/%s", h_dir, p))
		_ = os.write_entire_file(fmt.tprintf("%s/2026-10-30T10-00-0%d-000Z_%s-1.jsonl", store, i, p), transmute([]u8)fmt.tprintf("{{\"type\":\"session\",\"version\":3,\"id\":\"%s-1\",\"cwd\":\"%s/%s\"}}\n{{\"type\":\"message\",\"message\":{{\"role\":\"user\",\"content\":\"Title %s\"}}}}\n", p, h_dir, p, p))
	}
	old_home := os.get_env("HOME", context.temp_allocator)
	os.set_env("HOME", home)
	defer os.set_env("HOME", old_home)
	rescan_now()
	pa, pb: u64
	for p in state.projects {
		if strings.has_suffix(p.cwd, "/a") do pa = p.id
		if strings.has_suffix(p.cwd, "/b") do pb = p.id
	}
	run_command(Select_Project{project_id = pa}, H_UI)
	sa := run_command(Open_Session_Cmd{project_id = pa, pi_session_id = "a-1"}, H_UI).created_id
	testing.expect(t, sa != 0)
	run_command(Select_Project{project_id = pb}, H_UI)
	testing.expect_value(t, open_session_title(find_session(sa)), "Title a")
}

// 3. one pending entry per caller and target; at most 3 per caller
@(test)
confirmations_deduped_and_capped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	sess, _, _ := h_session(t)
	ctl := Caller{kind = .Control}
	sh := h_busy_shell(t, sess)
	r1 := run_command(Close_Tab{tab_id = sh}, ctl)
	r2 := run_command(Close_Tab{tab_id = sh}, ctl)
	testing.expect(t, r1.error == "needs_confirmation" && r2.error == "needs_confirmation")
	testing.expect_value(t, len(state.pending_confirmations), 1)
	// trusted: the same token again
	run_command(Set_Confirm_Policy{caller = .Control, class = .Tab_Close, mode = .Trusted}, H_UI)
	sh2 := h_busy_shell(t, sess)
	a := run_command(Close_Tab{tab_id = sh2}, ctl)
	b := run_command(Close_Tab{tab_id = sh2}, ctl)
	testing.expect(t, a.confirm_token != "" && a.confirm_token == b.confirm_token, "same token")
	testing.expect_value(t, len(state.pending_confirmations), 2)
	run_command(Quit{}, ctl)
	testing.expect_value(t, len(state.pending_confirmations), 3)
	sh3 := h_busy_shell(t, sess)
	testing.expect_value(t, run_command(Close_Tab{tab_id = sh3}, ctl).error, "too many confirmations waiting for this caller (max 3)")
	testing.expect_value(t, len(state.pending_confirmations), 3)
	// another caller has its own room
	testing.expect_value(t, run_command(Close_Tab{tab_id = sh3}, H_SCRIPT).error, "needs_confirmation")
}

// 4. a requester's confirmations go with its tab
@(test)
confirmations_forgotten_with_requester :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	sess, _, _ := h_session(t)
	sh := h_busy_shell(t, sess)
	testing.expect(t, run_command(Set_Home{open = true}, H_UI).ok)
	ht := home_tab().id
	run_command(Close_Tab{tab_id = sh}, {kind = .Control, tab_id = ht})
	testing.expect_value(t, len(state.pending_confirmations), 1)
	run_command(Tab_Exited{tab_id = ht})
	testing.expect_value(t, len(state.pending_confirmations), 0)
}

// 5. Home cannot hide its pane or move the keyboard away from it
@(test)
home_keeps_the_keyboard :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	testing.expect(t, run_command(Set_Home{open = true}, H_UI).ok)
	home := Caller{kind = .Control, tab_id = home_tab().id}
	testing.expect_value(t, run_command(Set_Home{open = false}, home).error, "only the user shows or hides the agent's drawer")
	testing.expect_value(t, run_command(Set_Home{open = false}, {kind = .Control}).error, "only the user shows or hides the agent's drawer")
	testing.expect_value(t, run_command(Set_Focus{widget = "palette"}, home).error, "the agent's terminal has the keyboard")
	testing.expect(t, state.home_open && state.focus_widget == "agent_input")
	testing.expect(t, run_command(Set_Home{open = false}, H_UI).ok)
	testing.expect(t, run_command(Set_Focus{widget = "rename_project"}, {kind = .Control}).ok, "pane shut: as before")
	testing.expect(t, !run_command(Set_Focus{widget = "palette"}, {kind = .Control}).ok, "the palette is the user's (it takes their keys)")
	run_command(Set_Focus{}, {kind = .Control})
	testing.expect(t, run_command(Set_Home{open = true}, {kind = .Control}).ok, "a control script may show it")
	testing.expect_value(t, run_command(Set_Home{open = true}, home).error, "only the user shows or hides the agent's drawer")
}

// 6. open_session never matches Home's session
@(test)
open_session_skips_home :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	testing.expect(t, run_command(Set_Home{open = true}, H_UI).ok)
	hs := home_session()
	p := run_command(Add_Project{cwd = hs.cwd}, H_UI).created_id
	r := run_command(Open_Session_Cmd{project_id = p, pi_session_id = hs.pi_session_id}, H_UI)
	testing.expect(t, r.created_id != state.home, "not Home")
	testing.expect(t, state.current_session != state.home, "Home never current")
}

// A long session title is cut in confirmation summaries (the bar keeps its buttons).
@(test)
confirmation_titles_are_cut :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	sess, _, _ := h_session(t)
	s := find_session(sess)
	long := strings.repeat("é", 100, context.temp_allocator) // 200 bytes
	f := fmt.tprintf("%s/long.jsonl", h_dir)
	_ = os.write_entire_file(f, transmute([]u8)fmt.tprintf("{{\"type\":\"session\",\"version\":3,\"id\":\"x\",\"cwd\":\"/tmp\"}}\n{{\"type\":\"message\",\"message\":{{\"role\":\"user\",\"content\":\"%s\"}}}}\n", long))
	s.session_file = strings.clone(f)
	sh := h_busy_shell(t, sess)
	r := run_command(Close_Tab{tab_id = sh}, H_SCRIPT)
	testing.expect(t, strings.contains(r.confirm_summary, "…?"), r.confirm_summary)
	testing.expect(t, len(r.confirm_summary) < 160, r.confirm_summary)
}
