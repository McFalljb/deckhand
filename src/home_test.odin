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
import "core"

@(private = "file")
H_UI :: core.Caller{kind = .UI}
@(private = "file")
H_SCRIPT :: core.Caller{kind = .Script}

@(private = "file")
h_dir: string
@(private = "file")
h_pin: string // the pi integration Home's pi loads (its DECKHAND_* environment comes with it)

@(private = "file")
h_reset :: proc(t: ^testing.T, socket := false) {
	context.allocator = runtime.heap_allocator()
	for _, x in core.terms {
		core.term_free(x)
		free(x)
	}
	clear(&core.terms)
	core.inbox_drain()
	state^ = core.State {
		layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT},
	}
	core.persist = {}
	core.platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	h_dir = fmt.aprintf("%s/pd-home-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory_all(h_dir)
	core.home_root = h_dir
	delete(core.home_fork_skip)
	core.home_fork_skip = ""
	if socket {
		h_pin = pi_integration_for_test(t)
		os.set_env("DECKHAND_RUNTIME_DIR", fmt.tprintf("%s/run", h_dir))
		rdir, ok := core.sock_runtime_dir(context.temp_allocator)
		testing.expect(t, ok, "runtime dir")
		testing.expect(t, core.socket_start(rdir), "socket_start")
	}
}

@(private = "file")
h_stop :: proc() {
	core.socket_stop(proc() {core.inbox_drain()})
	core.home_root = ""
	if h_pin != "" do pi_integration_test_done(h_pin)
	h_pin = ""
}

// A tiny socket client (the test thread pumps the inbox while it waits).
@(private = "file")
Hc :: struct {
	fd:     core.Sock_Fd,
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
		core.inbox_drain()
		if core.sock_wait_readable(c.fd, 5) {
			chunk: [16 * 1024]u8
			n := core.sock_read(c.fd, chunk[:])
			if n <= 0 do c.closed = true
			else do append(&c.buf, ..chunk[:n])
		}
	}
}

@(private = "file")
hc_req :: proc(c: ^Hc, id, line: string) -> string {
	core.sock_write_all(c.fd, transmute([]u8)strings.concatenate({line, "\n"}, context.temp_allocator))
	for {
		l := hc_recv(c)
		if l == "" do return ""
		if core.json_path(l, "id") == id do return l
		append(&c.lines, l)
	}
}

@(private = "file")
hc_cmd :: proc(c: ^Hc, cmd: string) -> string {
	return hc_req(c, "q", fmt.tprintf(`{{"id":"q","v":1,"type":"command","command":%s}}`, cmd))
}

@(private = "file")
hc_hello :: proc(token: string) -> (^Hc, string) {
	fd, ok := core.sock_connect(core.socket_path())
	if !ok do return nil, ""
	c := new(Hc)
	c.fd = fd
	return c, hc_req(c, "h", fmt.tprintf(`{{"id":"h","v":1,"type":"hello","token":"%s"}}`, token))
}

@(private = "file")
hc_close :: proc(c: ^Hc) {
	core.sock_close(c.fd)
	delete(c.buf)
	delete(c.lines)
	free(c)
}

// Opens Home with a fake pi that writes its environment tokens and arguments
// to files; returns Home's tab and its env tokens (bridge and control).
@(private = "file")
h_open_home :: proc(t: ^testing.T) -> (tab: u64, panel_tok, control_tok: string) {
	os.set_env("DECKHAND_CMD", fmt.tprintf(`printf '%%s\n' "$@" > %s/args.tmp; mv %s/args.tmp %s/args; printf %%s "$DECKHAND_TOKEN" > %s/ptok; printf %%s "$DECKHAND_CONTROL_TOKEN" > %s/ctok; exec sleep 30`, h_dir, h_dir, h_dir, h_dir, h_dir))
	r := core.run_command(core.Set_Home{open = true}, H_UI)
	testing.expect(t, r.ok, r.error)
	tab = r.created_id
	testing.expect_value(t, tab, core.home_tab().id)
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
	os.set_env("DECKHAND_CMD", "sleep 30")
	if state.selected_project == 0 do core.run_command(core.Add_Project{cwd = "/tmp"}, H_UI)
	sess = core.run_command(core.New_Chat{project_id = state.selected_project}, H_UI).created_id
	testing.expect(t, sess != 0, "new chat")
	pitab = core.find_session(sess).tabs[0].id
	shell = core.run_command(core.New_Shell_Tab{session = sess}, H_UI).created_id
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
	hs := core.home_session()
	testing.expect(t, hs != nil && hs.home && hs.project_id == 0)
	testing.expect_value(t, hs.session_dir, fmt.tprintf("%s/home", h_dir))
	testing.expect(t, os.is_dir(hs.session_dir))
	// a new Home session: pi's TUI gets --session-dir, --session-id and Atlas's prompt
	args, _ := os.read_entire_file(fmt.tprintf("%s/args", h_dir), context.temp_allocator)
	testing.expect(t, strings.contains(string(args), fmt.tprintf("--session-dir\n%s/home\n--session-id\n%s\n--append-system-prompt\n%s/atlas/ATLAS.md\n", h_dir, hs.pi_session_id, h_dir)), string(args))
	testing.expect(t, !strings.contains(string(args), "--mode"), string(args))
	// Deckhand's desk skill, which the Atlas prompt names (pi_integration_atlas_args)
	testing.expect(t, strings.contains(string(args), fmt.tprintf("--skill\n%s/skills/deckhand-desk\n", h_pin)), string(args))
	testing.expect(t, strings.contains(core.ATLAS_PROMPT_STARTER, "deckhand-desk skill"), "the prompt names the bundled skill")
	// the bridge token: a panel caller bound to Home's tab
	pc, pr := hc_hello(ptok)
	testing.expect_value(t, core.json_path(pr, "result.data.caller"), "panel")
	testing.expect_value(t, core.json_path(pr, "result.data.tab_id"), fmt.tprint(tab))
	hc_close(pc)

	c, r := hc_hello(ctok)
	testing.expect_value(t, core.json_path(r, "result.data.caller"), "control")
	testing.expect_value(t, core.json_path(r, "result.data.tab_id"), fmt.tprint(tab))
	testing.expect_value(t, core.json_path(r, "result.data.capabilities.0"), "commands")
	re := core.json_path(r, "result.data.reconnect_token")
	testing.expect_value(t, len(re), 64)
	// single use: the env token is gone, the reconnect token is the same caller
	c2, r2 := hc_hello(ctok)
	testing.expect_value(t, core.json_path(r2, "result.error"), "unknown token")
	c3, r3 := hc_hello(re)
	testing.expect_value(t, core.json_path(r3, "result.data.caller"), "control")
	testing.expect_value(t, core.json_path(r3, "result.data.tab_id"), fmt.tprint(tab))
	// state: Home is marked, has no project, and the drawer's field has the keyboard
	st := core.json_path(hc_cmd(c, `{"type":"get_state"}`), "result.ok")
	testing.expect_value(t, st, "true")
	testing.expect_value(t, core.json_path(core.state_json(), "home.tab_id"), fmt.tprint(tab))
	testing.expect_value(t, core.json_path(core.state_json(), "home.open"), "true")
	testing.expect_value(t, core.json_path(core.state_json(), "focus.id"), "agent_input")
	testing.expect_value(t, core.json_path(core.state_json(), "open_sessions.0.home"), "true")
	// the control token dies with Home's tab
	core.run_command(core.Tab_Exited{tab_id = tab})
	c4, r4 := hc_hello(re)
	testing.expect_value(t, core.json_path(r4, "result.error"), "unknown token")
	// opening again starts Home again (resuming its session) with new tokens
	os.remove(fmt.tprintf("%s/ctok", h_dir))
	tab2, _, ctok2 := h_open_home(t)
	testing.expect_value(t, tab2, tab)
	testing.expect(t, ctok2 != ctok)
	testing.expect(t, core.home_tab().status == .Running)
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
		testing.expect_value(t, core.json_path(r, "result.ok"), "false", loc = loc)
		testing.expect_value(t, core.json_path(r, "result.error"), want, loc = loc)
	}
	refused(t, c, fmt.tprintf(`{{"type":"close_tab","tab_id":%d}}`, tab), "a session's pi tab cannot be closed")
	refused(t, c, fmt.tprintf(`{{"type":"pi_prompt","tab_id":%d,"text":"hi"}}`, tab), "a caller cannot act on its own tab")
	refused(t, c, fmt.tprintf(`{{"type":"pi_reload","tab_id":%d}}`, tab), "a caller cannot act on its own tab")
	refused(t, c, fmt.tprintf(`{{"type":"pi_wait_idle","tab_id":%d}}`, tab), "a caller cannot act on its own tab")
	refused(t, c, fmt.tprintf(`{{"type":"send_text","tab_id":%d,"text":"x"}}`, tab), "a caller cannot act on its own tab")
	refused(t, c, fmt.tprintf(`{{"type":"close_session","session":%d}}`, state.home), "Home cannot be closed")
	refused(t, c, fmt.tprintf(`{{"type":"new_shell_tab","session":%d}}`, state.home), "Home has only its pi tab")
	refused(t, c, fmt.tprintf(`{{"type":"focus_tab","tab_id":%d}}`, tab), core.HOME_NOT_A_SESSION)
	// Home may act on other tabs
	r := hc_cmd(c, fmt.tprintf(`{{"type":"send_text","tab_id":%d,"text":"echo hi\n"}}`, shell))
	testing.expect_value(t, core.json_path(r, "result.ok"), "true")

	// any caller bound to a tab: nothing in its own session either
	bound := core.Caller{kind = .Control, tab_id = pitab}
	s, _, _ := core.find_tab(pitab)
	testing.expect_value(t, core.run_command(core.Close_Tab{tab_id = shell}, bound).error, "a caller cannot close its own tab")
	testing.expect_value(t, core.run_command(core.Send_Text{tab_id = shell, text = "x"}, bound).error, "a caller cannot act on its own tab")
	testing.expect_value(t, core.run_command(core.Close_Session{session = s.id}, bound).error, "a caller cannot close its own session")
	testing.expect_value(t, core.run_command(core.Pi_Prompt{tab_id = pitab, text = "x"}, bound).error, "a caller cannot act on its own tab")

	// own events: Home's control connection never sees its own tab's
	sub := hc_req(c, "s", `{"id":"s","v":1,"type":"subscribe"}`)
	testing.expect_value(t, core.json_path(sub, "result.ok"), "true")
	core.run_command(core.Pi_Status_Update{tab_id = tab, agent = .Working}, H_SCRIPT) // Home's own status
	core.run_command(core.Pi_Status_Update{tab_id = tab, agent = .Idle}, {kind = .Internal})
	core.run_command(core.Pi_Status_Update{tab_id = pitab, agent = .Working}, H_SCRIPT) // another tab: seen
	got_other, got_own := false, false
	for _ in 0 ..< 10 {
		l := hc_recv(c, 500)
		if l == "" do break
		if core.json_path(l, "event") != "command" do continue
		id := core.json_path(l, "command.tab_id")
		if id == fmt.tprint(pitab) do got_other = true
		if id == fmt.tprint(tab) do got_own = true
	}
	for l in c.lines do if core.json_path(l, "command.tab_id") == fmt.tprint(tab) do got_own = true
	testing.expect(t, got_other, "an event about another tab")
	testing.expect(t, !got_own, "no events about Home's own tab")
	// the filter itself
	testing.expect(t, !core.event_visible_to(core.Command_Event{caller = H_SCRIPT, command = core.Tab_Exited{tab_id = tab}}, {kind = .Control, tab_id = tab}))
	testing.expect(t, core.event_visible_to(core.Command_Event{caller = H_SCRIPT, command = core.Tab_Exited{tab_id = shell}}, {kind = .Control, tab_id = tab}))
	testing.expect(t, core.event_visible_to(core.Command_Event{caller = H_SCRIPT, command = core.Tab_Exited{tab_id = tab}}, {kind = .Control}))
}

@(test)
send_text_rules :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	sess, pitab, shell := h_session(t)
	ctl := core.Caller{kind = .Control}
	testing.expect_value(t, core.run_command(core.Send_Text{tab_id = pitab, text = "x"}, ctl).error, "send prompts to a pi tab with pi_prompt, not send_text")
	testing.expect(t, core.run_command(core.Send_Text{tab_id = shell, text = "true\n"}, ctl).ok, "control -> shell")
	// scripts and the user are unchanged
	testing.expect(t, core.run_command(core.Send_Text{tab_id = pitab, text = "x"}, H_SCRIPT).ok, "script -> pi")
	testing.expect(t, core.run_command(core.Send_Text{tab_id = pitab, text = "x"}, H_UI).ok, "ui -> pi")
	// a session whose pi waits for the user is the user's
	core.run_command(core.Pi_Status_Update{tab_id = pitab, agent = .Working, waiting = true}, H_SCRIPT)
	testing.expect_value(t, core.run_command(core.Send_Text{tab_id = shell, text = "x"}, ctl).error, "pi in this session is waiting for the user")
	testing.expect(t, core.run_command(core.Send_Text{tab_id = shell, text = "true\n"}, H_SCRIPT).ok, "script -> shell while waiting")
	_ = sess
}

@(test)
list_commands_per_caller :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	types :: proc(caller: core.Caller) -> map[string]string {
		r := core.run_command(core.List_Commands{}, caller)
		m := make(map[string]string, context.temp_allocator)
		if !r.ok do return m
		count, _ := strconv.parse_int(core.json_path(r.data, "commands.#"))
		for i in 0 ..< count {
			ty := core.json_path(r.data, fmt.tprintf("commands.%d.type", i))
			m[ty] = fmt.tprintf("%s|%s|%s|%s", core.json_path(r.data, fmt.tprintf("commands.%d.args", i)), core.json_path(r.data, fmt.tprintf("commands.%d.confirm_class", i)), core.json_path(r.data, fmt.tprintf("commands.%d.long_running", i)), core.json_path(r.data, fmt.tprintf("commands.%d.does", i)))
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
	testing.expect_value(t, len(pan), 39)
	testing.expect(t, "show_file" in pan, "panel lists show_file (shows the user a file in its own session)")
	for want in ([]string{"app_call", "app_screenshot", "app_input", "app_events", "new_app_tab", "app_restart", "app_close", "app_declared"}) do testing.expectf(t, want in pan, "panel lists %s (its own session's app tabs)", want)
	for not in ([]string{"claude.session", "claude.turn", "claude.comments", "claude.attached", "claude.todos", "claude.task", "claude.subagent", "claude.background", "claude_restart", "new_claude_tab", "claude_prompt"}) do testing.expectf(t, !(not in pan), "a pi tab does not list %s", not)
	// a Claude tab: what a pi tab may, minus the bridge's reports, plus its own claude.* reports
	cl := types({kind = .Panel, tab_id = 7, claude = true})
	testing.expect_value(t, len(cl), 39 - 5 + 10) // + claude.model, claude.readonly_ack, claude.background
	for want in ([]string{"claude.session", "claude.turn", "claude.comments", "claude.attached", "claude.todos", "claude.task", "claude.subagent", "claude.background", "claude.readonly_ack", "browser_read", "app_call", "get_state", "show_file"}) do testing.expectf(t, want in cl, "a Claude tab lists %s", want)
	for not in ([]string{"pi.session", "pi.status", "panel.set", "panel.remove", "pi.attached", "new_claude_tab", "claude_prompt", "claude_restart", "send_text", "pi_prompt", "close_tab"}) do testing.expectf(t, !(not in cl), "a Claude tab does not list %s", not)
	for want in ([]string{"get_state", "list_commands", "list_worktrees", "job_list", "job_runs", "pi.session", "pi.status", "panel.set", "panel.remove", "pi.attached", "browser_open", "browser_navigate", "browser_back", "browser_forward", "browser_reload", "browser_stop", "browser_tabs", "browser_read", "browser_screenshot", "browser_wait", "browser_console", "browser_network", "browser_comments", "browser_click", "browser_type", "browser_press", "browser_scroll", "browser_select", "browser_hover", "browser_upload"}) do testing.expectf(t, want in pan, "panel lists %s", want)
	testing.expect(t, !("browser_agent_stop" in pan), "Stop is the user's")
	testing.expect(t, !("browser_agent_take_over" in pan) && !("browser_upload_answer" in pan), "Take over and the upload bar are the user's")
	// the user: user-only settings, not bridge-only or internal ones
	ui := types(H_UI)
	testing.expect(t, "set_confirm_policy" in ui && "set_close_confirm" in ui && !("panel.set" in ui) && !("tab_exited" in ui))
	scr := types(H_SCRIPT)
	testing.expect(t, "pi.status" in scr && !("set_confirm_policy" in scr) && !("panel.set" in scr))
	// one table: every command type has exactly one row, and parses by that name
	testing.expect_value(t, len(core.COMMAND_SPECS), len(type_info_of(core.Command).variant.(runtime.Type_Info_Named).base.variant.(runtime.Type_Info_Union).variants))
	seen := make(map[string]bool, context.temp_allocator)
	for s in core.COMMAND_SPECS {
		testing.expectf(t, !seen[s.type], "one row per type: %s", s.type)
		seen[s.type] = true
		_, err := core.parse_command(fmt.tprintf(`{{"type":"%s"}}`, s.type), context.temp_allocator)
		unknown := strings.has_prefix(err, "unknown command")
		testing.expectf(t, unknown == (s.who == .Internal), "%s parses: %s", s.type, err)
	}
	for c in ([]core.Command{core.Tab_Exited{}, core.Rescan_Done{}, core.Bridge_Done{}, core.Restore_Session{}}) do testing.expectf(t, core.command_spec(core.command_type(c)) != nil, "row for %s", core.command_type(c))
	// and over the wire
	r := core.run_command(core.List_Commands{}, {kind = .Control})
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
	r := core.run_command(core.Close_Session{session = b}, H_SCRIPT)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect(t, r.confirm_by_user && r.confirm_token == "")
	testing.expect_value(t, len(state.pending_confirmations), 1)
	testing.expect_value(t, core.json_path(core.state_json(), "pending_confirmations.0.class"), "tab_close")
	testing.expect_value(t, core.json_path(core.state_json(), "pending_confirmations.0.command.type"), "close_session")
	testing.expect(t, core.find_session(b) != nil, "nothing closed yet")
	testing.expect_value(t, core.run_command(core.Close_Session{session = b, confirm = "nope"}, H_SCRIPT).error, "unknown or expired confirmation token")
	// the user confirms it (as the confirmation bar does)
	tok := state.pending_confirmations[0].token
	r = core.run_command(core.Close_Session{session = b, confirm = tok}, H_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, core.find_session(b) == nil, "closed")
	testing.expect(t, core.term_of(bpt) == nil && core.term_of(bsh) == nil, "its terminals stopped")
	testing.expect_value(t, len(state.pending_confirmations), 0)
	testing.expect_value(t, state.current_session, a) // the other open session
	// an idle session closes without asking
	core.run_command(core.Pi_Status_Update{tab_id = apt, agent = .Idle}, H_SCRIPT)
	r = core.run_command(core.Close_Session{session = a}, {kind = .Control})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(state.open_sessions), 0)
	testing.expect_value(t, state.current_session, 0)
	testing.expect_value(t, core.run_command(core.Close_Session{session = a}, H_UI).error, "no such session")
	// a pending close_session goes when the session goes another way
	c, _, _ := h_session(t)
	core.run_command(core.Close_Session{session = c}, H_SCRIPT)
	testing.expect_value(t, len(state.pending_confirmations), 1)
	core.run_command(core.Close_Session{session = c, confirm = state.pending_confirmations[0].token}, H_UI)
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
	core.rescan_now()
	p := state.projects[0].id
	core.run_command(core.Select_Project{project_id = p}, H_UI)
	s1 := core.run_command(core.Open_Session_Cmd{project_id = p, pi_session_id = "aaaa-1"}, H_UI).created_id
	s2 := core.run_command(core.Open_Session_Cmd{project_id = p, pi_session_id = "bbbb-2"}, H_UI).created_id
	testing.expect(t, s1 != 0 && s2 != 0)
	testing.expect(t, core.run_command(core.Set_Home{open = true}, H_UI).ok)
	hid := strings.clone(core.home_session().pi_session_id)
	testing.expect_value(t, core.home_session().cwd, core.home_dir()) // no main folder: the data dir's home/, never $HOME
	text := strings.clone(core.workspace_json())
	testing.expect(t, strings.contains(text, "aaaa-1") && strings.contains(text, "bbbb-2"), text)
	testing.expect(t, strings.contains(text, fmt.tprintf(`"home":{{"pi_session_id":"%s"}}`, hid)), text)
	testing.expect_value(t, strings.count(text, `"pi_session_id"`), 3) // Home is not an open session there
	testing.expect(t, strings.contains(text, `"drawer_open":true`), text) // reopens (and starts) at launch
	core.run_command(core.Set_Home{open = false}, H_UI)
	core.run_command(core.Pi_Status_Update{tab_id = core.find_session(s2).tabs[0].id, agent = .Idle}, H_SCRIPT)
	testing.expect(t, core.run_command(core.Close_Session{session = s2}, H_UI).ok)
	text = strings.clone(core.workspace_json())
	testing.expect(t, !strings.contains(text, "bbbb-2"), text)

	// relaunch: Home is back, not started, closed; opening starts it with its id
	h_reset(t)
	os.set_env("HOME", home)
	core.rescan_now()
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect_value(t, len(state.open_sessions), 2)
	hs := core.home_session()
	testing.expect(t, hs != nil && hs.home && hs.restored)
	testing.expect_value(t, hs.pi_session_id, hid)
	testing.expect(t, hs.tabs[0].status == .Not_Started && !state.home_open)
	testing.expect_value(t, core.json_path(core.state_json(), "open_sessions.1.tabs.0.status"), "not_started")
	// Home is never the current session and is not focusable as one
	testing.expect_value(t, core.run_command(core.Focus_Session{session = hs.id}, H_UI).error, core.HOME_NOT_A_SESSION)
	os.set_env("DECKHAND_CMD", fmt.tprintf(`printf '%%s\n' "$@" > %s/args.tmp; mv %s/args.tmp %s/args; exec sleep 30`, h_dir, h_dir, h_dir))
	testing.expect(t, core.run_command(core.Set_Home{open = true}, H_UI).ok)
	for _ in 0 ..< 200 {
		if os.exists(fmt.tprintf("%s/args", h_dir)) do break
		time.sleep(20 * time.Millisecond)
	}
	time.sleep(50 * time.Millisecond)
	args, _ := os.read_entire_file(fmt.tprintf("%s/args", h_dir), context.temp_allocator)
	testing.expect(t, strings.contains(string(args), fmt.tprintf("--session-id\n%s", hid)), string(args))
	// set_home false hides the pane; Home keeps running
	testing.expect(t, core.run_command(core.Set_Home{open = false}, H_UI).ok)
	testing.expect(t, !state.home_open && core.home_tab().status == .Running)
}

// ---- review round 1 ----

// A shell tab whose foreground program is not the shell (sleep).
@(private = "file")
h_busy_shell :: proc(t: ^testing.T, sess: u64) -> u64 {
	sh := core.run_command(core.New_Shell_Tab{session = sess}, H_UI).created_id
	core.run_command(core.Send_Text{tab_id = sh, text = "sleep 30\n"}, H_SCRIPT)
	for _ in 0 ..< 200 {
		if x := core.term_of(sh); x != nil && core.pty_foreground_busy(&x.pty) do return sh
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
	testing.expect_value(t, core.run_command(core.Send_Text{tab_id = sh, text = "y\n"}, {kind = .Control}).error, "a program is running in this tab; control callers type only at a shell prompt")
	testing.expect(t, core.run_command(core.Send_Text{tab_id = sh, text = "x"}, H_SCRIPT).ok, "scripts unchanged")
}

// 2. the bar says who asks and what
@(test)
confirmation_says_who_and_what :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	sess, _, _ := h_session(t)
	pname := core.project_name(core.find_project(state.selected_project)^)
	sh := h_busy_shell(t, sess)
	testing.expect(t, core.run_command(core.Set_Home{open = true}, H_UI).ok)
	home := core.Caller{kind = .Control, tab_id = core.home_tab().id}
	r := core.run_command(core.Close_Tab{tab_id = sh}, home)
	testing.expect_value(t, r.confirm_summary, fmt.tprintf("Atlas asks: close %q in %s · Untitled session? Its process is still running.", "shell 2", pname))
	r = core.run_command(core.Close_Tab{tab_id = sh}, H_SCRIPT)
	testing.expect(t, strings.has_prefix(r.confirm_summary, "A script asks: close "), r.confirm_summary)
	r = core.run_command(core.Quit{}, home)
	testing.expect_value(t, r.confirm_summary, "Atlas asks: quit Deckhand? Running sessions will be stopped.")
	r = core.run_command(core.Quit{}, H_UI)
	testing.expect_value(t, r.confirm_summary, "Quit Deckhand? Running sessions will be stopped.")
	testing.expect_value(t, core.json_path(core.state_json(), "pending_confirmations.0.summary"), fmt.tprintf("Atlas asks: close %q in %s · Untitled session? Its process is still running.", "shell 2", pname))
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
	core.rescan_now()
	pa, pb: u64
	for p in state.projects {
		if strings.has_suffix(p.cwd, "/a") do pa = p.id
		if strings.has_suffix(p.cwd, "/b") do pb = p.id
	}
	core.run_command(core.Select_Project{project_id = pa}, H_UI)
	sa := core.run_command(core.Open_Session_Cmd{project_id = pa, pi_session_id = "a-1"}, H_UI).created_id
	testing.expect(t, sa != 0)
	core.run_command(core.Select_Project{project_id = pb}, H_UI)
	testing.expect_value(t, core.open_session_title(core.find_session(sa)), "Title a")
}

// 3. one pending entry per caller and target; at most 3 per caller
@(test)
confirmations_deduped_and_capped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	sess, _, _ := h_session(t)
	ctl := core.Caller{kind = .Control}
	sh := h_busy_shell(t, sess)
	r1 := core.run_command(core.Close_Tab{tab_id = sh}, ctl)
	r2 := core.run_command(core.Close_Tab{tab_id = sh}, ctl)
	testing.expect(t, r1.error == "needs_confirmation" && r2.error == "needs_confirmation")
	testing.expect_value(t, len(state.pending_confirmations), 1)
	// trusted: the same token again
	core.run_command(core.Set_Confirm_Policy{caller = .Control, class = .Tab_Close, mode = .Trusted}, H_UI)
	sh2 := h_busy_shell(t, sess)
	a := core.run_command(core.Close_Tab{tab_id = sh2}, ctl)
	b := core.run_command(core.Close_Tab{tab_id = sh2}, ctl)
	testing.expect(t, a.confirm_token != "" && a.confirm_token == b.confirm_token, "same token")
	testing.expect_value(t, len(state.pending_confirmations), 2)
	core.run_command(core.Quit{}, ctl)
	testing.expect_value(t, len(state.pending_confirmations), 3)
	sh3 := h_busy_shell(t, sess)
	testing.expect_value(t, core.run_command(core.Close_Tab{tab_id = sh3}, ctl).error, "too many confirmations waiting for this caller (max 3)")
	testing.expect_value(t, len(state.pending_confirmations), 3)
	// another caller has its own room
	testing.expect_value(t, core.run_command(core.Close_Tab{tab_id = sh3}, H_SCRIPT).error, "needs_confirmation")
}

// 4. a requester's confirmations go with its tab
@(test)
confirmations_forgotten_with_requester :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	sess, _, _ := h_session(t)
	sh := h_busy_shell(t, sess)
	testing.expect(t, core.run_command(core.Set_Home{open = true}, H_UI).ok)
	ht := core.home_tab().id
	core.run_command(core.Close_Tab{tab_id = sh}, {kind = .Control, tab_id = ht})
	testing.expect_value(t, len(state.pending_confirmations), 1)
	core.run_command(core.Tab_Exited{tab_id = ht})
	testing.expect_value(t, len(state.pending_confirmations), 0)
}

// 5. Home cannot hide its pane or move the keyboard away from it
@(test)
home_keeps_the_keyboard :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	testing.expect(t, core.run_command(core.Set_Home{open = true}, H_UI).ok)
	home := core.Caller{kind = .Control, tab_id = core.home_tab().id}
	testing.expect_value(t, core.run_command(core.Set_Home{open = false}, home).error, "only the user shows or hides the agent's drawer")
	testing.expect_value(t, core.run_command(core.Set_Home{open = false}, {kind = .Control}).error, "only the user shows or hides the agent's drawer")
	testing.expect_value(t, core.run_command(core.Set_Focus{widget = "palette"}, home).error, "the agent's terminal has the keyboard")
	testing.expect(t, state.home_open && state.focus_widget == "agent_input")
	testing.expect(t, core.run_command(core.Set_Home{open = false}, H_UI).ok)
	testing.expect(t, core.run_command(core.Set_Focus{widget = "rename_project"}, {kind = .Control}).ok, "pane shut: as before")
	testing.expect(t, !core.run_command(core.Set_Focus{widget = "palette"}, {kind = .Control}).ok, "the palette is the user's (it takes their keys)")
	core.run_command(core.Set_Focus{}, {kind = .Control})
	testing.expect(t, core.run_command(core.Set_Home{open = true}, {kind = .Control}).ok, "a control script may show it")
	testing.expect_value(t, core.run_command(core.Set_Home{open = true}, home).error, "only the user shows or hides the agent's drawer")
}

// 6. open_session never matches Home's session
@(test)
open_session_skips_home :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	testing.expect(t, core.run_command(core.Set_Home{open = true}, H_UI).ok)
	hs := core.home_session()
	p := core.run_command(core.Add_Project{cwd = hs.cwd}, H_UI).created_id
	r := core.run_command(core.Open_Session_Cmd{project_id = p, pi_session_id = hs.pi_session_id}, H_UI)
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
	s := core.find_session(sess)
	long := strings.repeat("é", 100, context.temp_allocator) // 200 bytes
	f := fmt.tprintf("%s/long.jsonl", h_dir)
	_ = os.write_entire_file(f, transmute([]u8)fmt.tprintf("{{\"type\":\"session\",\"version\":3,\"id\":\"x\",\"cwd\":\"/tmp\"}}\n{{\"type\":\"message\",\"message\":{{\"role\":\"user\",\"content\":\"%s\"}}}}\n", long))
	s.session_file = strings.clone(f)
	sh := h_busy_shell(t, sess)
	r := core.run_command(core.Close_Tab{tab_id = sh}, H_SCRIPT)
	testing.expect(t, strings.contains(r.confirm_summary, "…?"), r.confirm_summary)
	testing.expect(t, len(r.confirm_summary) < 160, r.confirm_summary)
}

// ---- Atlas's working folder ----

// Where Atlas's pi ran (`pwd -P`, written by the stand-in pi), after waiting for it.
@(private = "file")
h_pi_cwd :: proc(t: ^testing.T) -> string {
	f := fmt.tprintf("%s/pwd", h_dir)
	for _ in 0 ..< 750 { 	// up to 15 s: the unit runner runs 6 processes at once
		if os.exists(f) do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, os.exists(f), "the stand-in pi started")
	b, _ := os.read_entire_file(f, context.temp_allocator)
	os.remove(f)
	return strings.trim_space(string(b))
}

// Atlas starts in the main folder when it is set and reachable, else in the
// data dir's home/ — never in the user's home folder (macOS privacy prompts
// for Desktop, Documents, Downloads). A change of main folder applies at
// Atlas's next start; a restored Atlas starts there too, resuming its session.
@(test)
atlas_cwd_is_the_main_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h_reset(t)
	defer h_stop()
	for n in ([]string{"userhome", "main1", "main2"}) do os.make_directory_all(fmt.tprintf("%s/%s", h_dir, n))
	home := core.real_path(fmt.aprintf("%s/userhome", h_dir))
	old_home := os.get_env("HOME", context.temp_allocator)
	os.set_env("HOME", home)
	defer os.set_env("HOME", old_home)
	main1 := core.real_path(fmt.aprintf("%s/main1", h_dir))
	main2 := core.real_path(fmt.aprintf("%s/main2", h_dir))
	data_home := core.real_path(core.home_dir())
	cmd := fmt.aprintf(`printf '%%s\n' "$@" > %s/args; pwd -P > %s/pwd.tmp; mv %s/pwd.tmp %s/pwd; exec sleep 30`, h_dir, h_dir, h_dir, h_dir)
	os.set_env("DECKHAND_CMD", cmd)
	dir := h_dir
	relaunch := proc(t: ^testing.T, dir, cmd, text: string, main: string) {
		h_reset(t)
		h_dir, core.home_root = dir, dir
		os.set_env("DECKHAND_CMD", cmd)
		testing.expect_value(t, core.workspace_restore(text), "")
		state.settings.home_dir = main
	}

	// unset: the data dir's home/, not $HOME
	state.settings.home_dir = ""
	testing.expect_value(t, core.real_path(core.home_cwd()), data_home)
	// set but not reachable: the data dir's home/
	state.settings.home_dir = fmt.aprintf("%s/gone", h_dir)
	testing.expect_value(t, core.real_path(core.home_cwd()), data_home)
	// set and reachable: the main folder
	state.settings.home_dir = main1
	testing.expect_value(t, core.home_cwd(), main1)

	testing.expect(t, core.run_command(core.Set_Home{open = true}, H_UI).ok)
	testing.expect_value(t, core.home_session().cwd, main1)
	testing.expect_value(t, h_pi_cwd(t), main1)

	// the main folder changes while Atlas runs: it stays where it is until its next start
	state.settings.home_dir = main2
	testing.expect_value(t, core.home_session().cwd, main1)
	core.stop_pi_tab(core.home_tab())
	testing.expect(t, core.run_command(core.Set_Home{open = true}, H_UI).ok)
	testing.expect_value(t, core.home_session().cwd, main2)
	testing.expect_value(t, h_pi_cwd(t), main2)
	hid := strings.clone(core.home_session().pi_session_id)

	// relaunch with a session file in Home's session dir: restored, resumed, in the main folder
	// (the drawer saved shut: Atlas starts when it is opened, after the main folder is set)
	core.run_command(core.Set_Home{open = false}, H_UI)
	text := strings.clone(core.workspace_json())
	_ = os.write_entire_file(fmt.tprintf("%s/2026-10-30T10-00-00-000Z_%s.jsonl", core.home_dir(), hid), transmute([]u8)fmt.tprintf(`{{"type":"session","version":3,"id":"%s","cwd":"%s"}}`+"\n", hid, main1)) // recorded where it resumes: no fork
	relaunch(t, dir, cmd, text, main1)
	hs := core.home_session()
	testing.expect(t, hs != nil && hs.restored && hs.pi_session_id == hid)
	testing.expect(t, core.run_command(core.Set_Home{open = true}, H_UI).ok)
	testing.expect_value(t, h_pi_cwd(t), main1)
	args, _ := os.read_entire_file(fmt.tprintf("%s/args", h_dir), context.temp_allocator)
	testing.expect(t, strings.contains(string(args), "\n--session\n") && strings.contains(string(args), fmt.tprintf("_%s.jsonl\n", hid)), string(args)) // resumed, not a new session

	// relaunch with the main folder gone: the data dir's home/
	relaunch(t, dir, cmd, text, fmt.aprintf("%s/gone", dir))
	testing.expect(t, core.run_command(core.Set_Home{open = true}, H_UI).ok)
	testing.expect_value(t, h_pi_cwd(t), data_home)
}

// ---- Atlas's session moves to its new folder (pi --fork, once) ----

@(private = "file")
Hf :: struct {
	main, home, old: string, // the main folder, $HOME, the old session file
}

@(private = "file")
HF_CMD :: `printf '%%s\n' "$@" > %s/args; pwd -P > %s/pwd.tmp; mv %s/pwd.tmp %s/pwd; exec sleep 30`

// A data dir, a main folder, and Atlas's old session (its header's cwd = `cwd`:
// "$HOME", "$MAIN" or a path; header "" = that line instead). restore: Home
// restored, not started.
@(private = "file")
hf_setup :: proc(t: ^testing.T, cwd: string, header := "", restore := true) -> Hf {
	h_reset(t)
	core.persist_init(h_dir)
	f: Hf
	for n in ([]string{"userhome", "main"}) do os.make_directory_all(fmt.tprintf("%s/%s", h_dir, n))
	f.home = core.real_path(fmt.aprintf("%s/userhome", h_dir))
	f.main = core.real_path(fmt.aprintf("%s/main", h_dir))
	os.set_env("HOME", f.home)
	state.settings.home_dir = f.main
	at := cwd == "$HOME" ? f.home : cwd == "$MAIN" ? f.main : cwd
	line := header != "" ? header : fmt.tprintf(`{{"type":"session","version":3,"id":"old-1","cwd":"%s"}}`, at)
	f.old = fmt.aprintf("%s/2026-10-30T10-00-00-000Z_old-1.jsonl", core.home_dir())
	_ = os.write_entire_file(f.old, transmute([]u8)fmt.tprintf("%s\n{{\"type\":\"message\",\"message\":{{\"role\":\"user\",\"content\":\"hi\"}}}}\n", line))
	os.set_env("DECKHAND_CMD", fmt.tprintf(HF_CMD, h_dir, h_dir, h_dir, h_dir))
	if restore do testing.expect(t, core.run_command(core.Restore_Session{pi_session_id = "old-1", home = true}, {kind = .Internal}).ok)
	return f
}

// A relaunch on the same data dir from a workspace's text (the main folder as set then).
@(private = "file")
hf_relaunch :: proc(t: ^testing.T, text: string) {
	dir := h_dir
	h_reset(t)
	h_dir, core.home_root = dir, dir
	core.persist_init(h_dir)
	os.set_env("DECKHAND_CMD", fmt.tprintf(HF_CMD, h_dir, h_dir, h_dir, h_dir))
	testing.expect_value(t, core.workspace_restore(text), "")
}

// A saved workspace with only Home (old-1), the main folder, and what must survive a restore.
@(private = "file")
hf_workspace :: proc(f: Hf, drawer_open := false) -> string {
	return fmt.aprintf(`{{"v":%d,"projects":[],"open_sessions":[],"home":{{"pi_session_id":"old-1"}},"claude_readonly_ids":["ro-1"],"claude_sessions":[],"sidebar":{{"pinned_projects":["%s"]}},"layout":{{"left_width":300,"right_width":320,"right_open":true,"panels":[],"collapsed":[]%s}},"settings":{{"home_dir":"%s","setup_seen":true}}}}`+"\n", core.WORKSPACE_VERSION, f.main, drawer_open ? `,"drawer_open":true` : "", f.main)
}

// Starts (or restarts) Atlas; its pi's arguments.
@(private = "file")
hf_start :: proc(t: ^testing.T) -> string {
	if ht := core.home_tab(); ht != nil && ht.status == .Running do core.stop_pi_tab(ht)
	os.remove(fmt.tprintf("%s/args", h_dir)) // never the previous start's
	os.remove(fmt.tprintf("%s/pwd", h_dir))
	testing.expect(t, core.run_command(core.Set_Home{open = true}, H_UI).ok)
	return hf_args(t)
}

@(private = "file")
hf_args :: proc(t: ^testing.T) -> string {
	_ = h_pi_cwd(t)
	b, _ := os.read_entire_file(fmt.tprintf("%s/args", h_dir), context.temp_allocator)
	return strings.clone(string(b), context.temp_allocator)
}

// pi was told to fork the old file into session `id` (paths may be spelled through /private).
@(private = "file")
hf_forked :: proc(args, id: string) -> bool {
	i := strings.index(args, "--fork\n")
	return i >= 0 && strings.contains(args[i:], fmt.tprintf("_old-1.jsonl\n--session-id\n%s\n", id))
}

@(private = "file")
hf_resumed :: proc(args, id: string) -> bool {
	return !strings.contains(args, "--fork") && strings.contains(args, "\n--session\n") && strings.contains(args, fmt.tprintf("_%s.jsonl\n", id))
}

@(private = "file")
hf_saved :: proc() -> string {
	b, _ := os.read_entire_file(fmt.tprintf("%s/workspace.json", h_dir), context.temp_allocator)
	return string(b)
}

// pi wrote the fork of old-1 into `id`, recorded in `cwd`.
@(private = "file")
hf_write_fork :: proc(id, cwd: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/2026-11-04T10-00-00-000Z_%s.jsonl", core.home_dir(), id), transmute([]u8)fmt.tprintf(`{{"type":"session","version":3,"id":"%s","cwd":"%s"}}`+"\n", id, cwd))
}

// From another folder: forked into an id derived from the old id and the folder (the same
// whatever was saved), never saved mid-start; the old file kept as it was.
@(test)
atlas_session_forks_once_into_the_new_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	f := hf_setup(t, "$HOME")
	defer h_stop()
	id := core.home_fork_id("old-1", f.main)
	testing.expect(t, id != "old-1" && id == core.home_fork_id("old-1", f.main) && id != core.home_fork_id("old-1", f.home), id)
	testing.expect(t, id != core.home_fork_id("old-2", f.main), "another session: another id")
	before, _ := os.read_entire_file(f.old, context.allocator)
	args := hf_start(t)
	testing.expect_value(t, core.home_session().pi_session_id, id)
	testing.expect(t, hf_forked(args, id), args)
	testing.expect(t, !strings.contains(args, "\n--session\n"), args)
	testing.expect_value(t, hf_saved(), "") // the normal save cycle saves it, not the start
	after, _ := os.read_entire_file(f.old, context.temp_allocator)
	testing.expect(t, string(after) == string(before), "the old file is untouched")
	testing.expect(t, core.persist_dirty(), "the new id is saved by the next save")

	// a relaunch before any save and before pi wrote the fork: the same id again
	hf_relaunch(t, hf_workspace(f))
	state.settings.home_dir = f.main
	testing.expect(t, hf_forked(hf_start(t), id))
	// a relaunch after a save (the new id and fork_from) before pi wrote it: the same fork
	core.persist_save()
	saved := strings.clone(hf_saved())
	testing.expect(t, strings.contains(saved, fmt.tprintf(`"pi_session_id":"%s"`, id)) && strings.contains(saved, `"fork_from"`), saved)
	hf_relaunch(t, saved)
	testing.expect(t, hf_forked(hf_start(t), id))

	// pi wrote the fork: later starts resume it; fork_from goes
	hf_write_fork(id, f.main)
	testing.expect(t, hf_resumed(hf_start(t), id))
	core.persist_save()
	testing.expect(t, !strings.contains(hf_saved(), "fork_from"), hf_saved())
	// and a relaunch from a workspace still naming old-1 (never saved): the fork is resumed, not made again
	hf_relaunch(t, hf_workspace(f))
	testing.expect(t, hf_resumed(hf_start(t), id))
	testing.expect_value(t, core.home_session().pi_session_id, id)
}

// Review 1: a restore that opens Atlas (drawer_open) and forks never writes workspace.json
// mid-restore (what loads after the drawer, Claude sessions and the sidebar, would be lost).
@(test)
atlas_fork_never_saves_mid_restore :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	f := hf_setup(t, "$HOME", restore = false)
	defer h_stop()
	text := hf_workspace(f, drawer_open = true)
	_ = os.write_entire_file(fmt.tprintf("%s/workspace.json", h_dir), transmute([]u8)text)
	core.persist_load()
	args := hf_args(t)
	testing.expect(t, hf_forked(args, core.home_fork_id("old-1", f.main)), args)
	testing.expect_value(t, hf_saved(), text) // right after the fork: as it was
	testing.expect(t, slice_has(state.claude_readonly_ids[:], "ro-1"), "claude_readonly_ids restored")
}

@(private = "file")
slice_has :: proc(xs: []string, x: string) -> bool {
	for y in xs do if y == x do return true
	return false
}

// Review 3: a fork that fails (pi exits, its file never written) drops the fork: the old
// session is resumed next time, where it was, and the terminal says so.
@(test)
atlas_failed_fork_resumes_the_old_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	f := hf_setup(t, "$HOME")
	defer h_stop()
	id := core.home_fork_id("old-1", f.main)
	testing.expect(t, hf_forked(hf_start(t), id))
	ht := core.home_tab()
	if x := core.term_of(ht.id); x != nil do x.running = false
	testing.expect(t, core.run_command(core.Tab_Exited{tab_id = ht.id, exit = {known = true, code = 1}}, {kind = .Internal}).ok)
	testing.expect_value(t, state.home_fork_from, "")
	testing.expect_value(t, core.home_session().pi_session_id, "old-1")
	if x := core.term_of(ht.id); x != nil do testing.expect(t, strings.contains(gt_screen_text(x.gt), "could not move"), gt_screen_text(x.gt))
	else do testing.fail_now(t, "its terminal is kept")
	args := hf_start(t)
	testing.expect(t, hf_resumed(args, "old-1"), args)
	testing.expect_value(t, core.home_session().pi_session_id, "old-1")
}

// The same folder (after realpath), an unreadable header, a header without cwd, an old pi, a
// main folder set but unreachable (an unmounted volume: no copies as it comes and goes):
// resumed as before.
@(test)
atlas_session_resumes_without_a_fork :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	Case :: struct {
		name, cwd, header, pi: string,
		main_gone:            bool,
	}
	for c in ([]Case{
		{"same folder", "$MAIN", "", "", false},
		{"not JSON", "", "not a header", "", false},
		{"no cwd", "", `{"type":"session","version":3,"id":"old-1"}`, "", false},
		{"no header line", "", strings.repeat("x", 200_000, context.temp_allocator), "", false},
		{"old pi", "$HOME", "", "1.3.0", false},
		{"main folder unreachable", "$MAIN", "", "", true},
	}) {
		f := hf_setup(t, c.cwd, c.header)
		if c.name == "same folder" { 	// the same folder by another spelling: a symlink to it
			link := fmt.tprintf("%s/link", h_dir)
			os.symlink(f.main, link)
			_ = os.write_entire_file(f.old, transmute([]u8)fmt.tprintf(`{{"type":"session","version":3,"id":"old-1","cwd":"%s"}}`+"\n", link))
		}
		if c.main_gone do state.settings.home_dir = fmt.aprintf("%s/unmounted", h_dir)
		state.reload.pi_version = c.pi
		args := hf_start(t)
		testing.expectf(t, hf_resumed(args, "old-1"), "%s: %s", c.name, args)
		testing.expectf(t, core.home_session().pi_session_id == "old-1", "%s: id %s", c.name, core.home_session().pi_session_id)
		state.reload.pi_version = ""
		h_stop()
	}
}

// Review 4: a main folder that is the home folder itself: Atlas still never runs in ~.
@(test)
atlas_never_in_home_even_as_main_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	f := hf_setup(t, "$HOME", restore = false)
	defer h_stop()
	state.settings.home_dir = f.home
	testing.expect_value(t, core.real_path(core.home_cwd()), core.real_path(core.home_dir()))
	os.symlink(f.home, fmt.tprintf("%s/homelink", h_dir))
	state.settings.home_dir = fmt.tprintf("%s/homelink", h_dir) // by another spelling too
	testing.expect_value(t, core.real_path(core.home_cwd()), core.real_path(core.home_dir()))
}

// Review 2, a pending fork: the main folder goes away before pi wrote the copy: the old
// session, where it was; the fork is dropped (no copy into the data dir's home/).
@(test)
atlas_pending_fork_dropped_when_the_main_folder_goes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	f := hf_setup(t, "$HOME")
	defer h_stop()
	testing.expect(t, hf_forked(hf_start(t), core.home_fork_id("old-1", f.main)))
	state.settings.home_dir = fmt.aprintf("%s/unmounted", h_dir)
	args := hf_start(t)
	testing.expect(t, hf_resumed(args, "old-1"), args)
	testing.expect_value(t, core.home_session().pi_session_id, "old-1")
	testing.expect_value(t, state.home_fork_from, "")
}
