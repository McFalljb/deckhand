package main

// Deckhand's pi integration (pi_integration.odin, integrations/pi): which `-e` paths a pi start
// gets, the DECKHAND_* environment of pi tabs and Atlas, and the minimum pi.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
pin_dir :: proc(t: ^testing.T) -> string {
	dir := fmt.aprintf("%s/pd-pi-int-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory_all(dir)
	manifest := `{"about": "x", "extensions": [
		{"name": "bridge", "required": true, "does": "a"},
		{"name": "desk", "required": true},
		{"name": "extra", "required": false, "does": "an optional one"},
		{"name": "../escape", "required": true},
		{"name": "gone", "required": true},
		{"name": "guard", "required": false, "default": true, "does": "on by default"}
	]}`
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/extensions.json", dir), transmute([]u8)manifest) == nil)
	os.make_directory_all(fmt.tprintf("%s/lib", dir))
	for n in ([]string{"bridge", "desk", "extra", "guard"}) {
		os.make_directory_all(fmt.tprintf("%s/extensions/%s", dir, n))
		_ = os.write_entire_file(fmt.tprintf("%s/extensions/%s/index.ts", dir, n), transmute([]u8)string("export default function () {}\n"))
	}
	os.make_directory_all(fmt.tprintf("%s/skills/deckhand-desk", dir))
	_ = os.write_entire_file(fmt.tprintf("%s/skills/deckhand-desk/SKILL.md", dir), transmute([]u8)string("---\nname: deckhand-desk\ndescription: x\n---\n"))
	return dir
}

// Other tests: a minimal integration folder as the override (a pi start loads it, so a pi tab
// gets the DECKHAND_* environment). Undo with pi_integration_test_done.
pi_integration_for_test :: proc(t: ^testing.T) -> string {
	dir := pin_dir(t)
	pi_integration_override = dir
	pi_integration_forget()
	return dir
}

pi_integration_test_done :: proc(dir: string) {
	pi_integration_override = ""
	pi_integration_forget()
	os.remove_all(dir)
	delete(dir)
}

@(test)
pi_integration_args_follow_the_manifest :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := pin_dir(t)
	defer os.remove_all(dir)
	pi_integration_override = dir
	defer pi_integration_override = ""
	old := state.reload.pi_version
	defer state.reload.pi_version = old
	state.reload.pi_version = ""
	pi_integration_forget()
	defer pi_integration_forget()
	// required ones in the manifest's order, one -e each; an optional one by its default (extra:
	// off, guard: on) unless turned on or off; a name that is not a plain folder name, or whose
	// folder is missing, is skipped
	args := pi_integration_args()
	testing.expect_value(t, strings.join(args, " ", context.temp_allocator), fmt.tprintf("-e %s/extensions/bridge -e %s/extensions/desk -e %s/extensions/guard", dir, dir, dir))
	pi_integration_optional_on = proc(name: string) -> bool {return name == "extra"}
	defer pi_integration_optional_on = nil
	args = pi_integration_args()
	testing.expect_value(t, strings.join(args, " ", context.temp_allocator), fmt.tprintf("-e %s/extensions/bridge -e %s/extensions/desk -e %s/extensions/extra", dir, dir, dir))
	// a known pi older than PI_MIN_VERSION: none (the tab's bar says why); unknown or new enough: all
	state.reload.pi_version = "1.3.9"
	testing.expect_value(t, len(pi_integration_args()), 0)
	testing.expect(t, pi_too_old())
	state.reload.pi_version = "1.4.0"
	testing.expect_value(t, len(pi_integration_args()), 6) // bridge, desk, extra
	testing.expect(t, !pi_too_old())
	state.reload.pi_version = "1.10.2"
	testing.expect(t, !pi_too_old())
	// no integration in this build: none
	pi_integration_override = "/nonexistent/deckhand-pi"
	pi_integration_forget()
	testing.expect_value(t, len(pi_integration_args()), 0)
	testing.expect_value(t, pi_integration_dir(), "")
}

// A pi tab's and Atlas's environment: DECKHAND_SOCKET, DECKHAND_TOKEN (Atlas: also
// DECKHAND_CONTROL_TOKEN) and DECKHAND_SHOTS_DIR; never pi-kit's PI_DESK_SOCKET, PI_DESK_TOKEN
// or PI_DESK_CONTROL_TOKEN, so an installed pi-kit's desk extensions stay inert. App tabs keep
// PI_DESK_SOCKET and PI_DESK_TOKEN (docs/ENGINE-BRIDGE.md). Inherited ones are dropped.
@(test)
pi_tab_env_is_deckhands_own :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fmt.aprintf("%s/pd-pi-env-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.set_env("PI_DESK_RUNTIME_DIR", dir)
	defer os.unset_env("PI_DESK_RUNTIME_DIR")
	rdir, ok := sock_runtime_dir(context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, socket_start(rdir))
	defer socket_stop(proc() {inbox_drain()})
	defer socket_forget_tab(4343)
	names :: proc(env: []string) -> string {
		out := make([dynamic]string, context.temp_allocator)
		for e in env {
			k, _, _ := strings.partition(e, "=")
			bridge := k == "PI_DESK_SOCKET" || k == "PI_DESK_TOKEN" || k == "PI_DESK_CONTROL_TOKEN" || k == "PI_DESK_SHOTS_DIR"
			if bridge || strings.has_prefix(k, "DECKHAND_") do append(&out, k) // the bridge's (the test run's own PI_DESK_CMD and the rest are inherited)
		}
		return strings.join(out[:], " ", context.temp_allocator)
	}
	pin := pi_integration_for_test(t)
	defer pi_integration_test_done(pin)
	old_v := state.reload.pi_version
	defer state.reload.pi_version = old_v
	state.reload.pi_version = ""
	for k in ([]string{"DECKHAND_SOCKET", "DECKHAND_TOKEN", "DECKHAND_CONTROL_TOKEN", "DECKHAND_SHOTS_DIR", "PI_DESK_SOCKET", "PI_DESK_TOKEN"}) do os.set_env(k, "/inherited")
	defer for k in ([]string{"DECKHAND_SOCKET", "DECKHAND_TOKEN", "DECKHAND_CONTROL_TOKEN", "DECKHAND_SHOTS_DIR", "PI_DESK_SOCKET", "PI_DESK_TOKEN"}) do os.unset_env(k)
	testing.expect_value(t, names(child_env(socket_pi_env({kind = .Panel, tab_id = 4343}))), "DECKHAND_SOCKET DECKHAND_TOKEN DECKHAND_SHOTS_DIR")
	testing.expect_value(t, names(child_env(agent_env(4343))), "DECKHAND_SOCKET DECKHAND_TOKEN DECKHAND_CONTROL_TOKEN DECKHAND_SHOTS_DIR")
	testing.expect_value(t, names(socket_child_env({kind = .App, tab_id = 4343})), "PI_DESK_SOCKET PI_DESK_TOKEN")
	testing.expect_value(t, names(child_env()), "") // a shell tab inherits none of them
	for e in agent_env(4343) do if strings.has_prefix(e, "DECKHAND_CONTROL_TOKEN=") do testing.expect_value(t, len(e), len("DECKHAND_CONTROL_TOKEN=") + 64)
	// a pi that will not load the integration (too old, or none in this build) gets no token at
	// all: its bash and ! commands would inherit one nothing uses (Atlas's: a control token)
	state.reload.pi_version = "1.3.0"
	testing.expect_value(t, names(child_env(socket_pi_env({kind = .Panel, tab_id = 4343}))), "")
	testing.expect_value(t, names(child_env(agent_env(4343))), "")
	state.reload.pi_version = ""
	pi_integration_override = "/nonexistent/deckhand-pi"
	pi_integration_forget()
	testing.expect_value(t, names(child_env(socket_pi_env({kind = .Panel, tab_id = 4343}))), "")
	testing.expect_value(t, names(child_env(agent_env(4343))), "")
}

// PI_DESK_PI_INTEGRATION (another integration folder) counts only in test mode: a release
// build never loads extensions from a folder an environment variable names.
@(test)
pi_integration_env_only_in_test_mode :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := pin_dir(t)
	defer os.remove_all(dir)
	os.set_env("PI_DESK_PI_INTEGRATION", dir)
	defer os.unset_env("PI_DESK_PI_INTEGRATION")
	testing.expect_value(t, pi_integration_from_env(test = false), "")
	testing.expect_value(t, pi_integration_from_env(test = true), dir)
	os.set_env("PI_DESK_PI_INTEGRATION", "relative/pi")
	testing.expect_value(t, pi_integration_from_env(test = true), "")
}

// The integration's folder is watched like pi's own extensions: a change there shows the bar
// over pi tabs (pi's /reload runs the -e extensions again).
@(test)
pi_integration_is_watched :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	pin := pi_integration_for_test(t)
	defer pi_integration_test_done(pin)
	os.set_env("PI_CODING_AGENT_DIR", fmt.tprintf("%s/agent", pin)) // never the user's
	defer os.unset_env("PI_CODING_AGENT_DIR")
	defer reload_build({})
	reload_build({pin})
	src := reload_sources_for_test()
	real := fs_real(pin, context.temp_allocator)
	for want in ([]string{fmt.tprintf("%s/extensions/", real), fmt.tprintf("%s/lib/", real)}) {
		scope, ok := src[want]
		testing.expectf(t, ok && scope == "", "watched for every pi tab: %s", want)
	}
	scope, ok := src[fmt.tprintf("%s/extensions.json", pin)]
	testing.expect(t, ok && scope == "", "its manifest")
}

// The integration's folders come after every project's: under RELOAD_DIRS_MAX a project's .pi
// keeps its watch, and the integration (which changes with Deckhand) is what is left out.
@(test)
pi_integration_watch_never_crowds_out_a_project :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	pin := pi_integration_for_test(t)
	defer pi_integration_test_done(pin)
	os.set_env("PI_CODING_AGENT_DIR", fmt.tprintf("%s/agent", pin)) // never the user's
	defer os.unset_env("PI_CODING_AGENT_DIR")
	defer reload_build({})
	// the agent dir's 4 folders + 15 projects x 4 = RELOAD_DIRS_MAX
	dirs := []string{"extensions", "skills", "prompts", "themes"} // reload.odin's RESOURCE_DIRS
	n := (RELOAD_DIRS_MAX - len(dirs)) / len(dirs)
	cwds := make([dynamic]string, context.temp_allocator)
	base := fs_real(pin, context.temp_allocator) // the watched paths are real ones
	for i in 0 ..< n do append(&cwds, fmt.tprintf("%s/proj-%d", base, i))
	reload_build(cwds[:])
	src := reload_sources_for_test()
	for c in cwds do for d in dirs {
		_, ok := src[fmt.tprintf("%s/.pi/%s/", c, d)]
		testing.expectf(t, ok, "a project's folder keeps its watch: %s/.pi/%s", c, d)
	}
}

// Below PI_MIN_VERSION a pi tab's bar says what is off and how to update; the setup sheet too.
@(test)
pi_too_old_says_so :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	old := state.reload.pi_version
	defer state.reload.pi_version = old
	tab := Tab{id = 5151, kind = Pi_Tab{}, status = .Running}
	tab.reload.version = "1.3.2"
	msg := pi_status_message(&tab)
	testing.expect(t, strings.contains(msg, "pi 1.3.2 is older than 1.4.0"), msg)
	testing.expect(t, strings.contains(msg, "pi update"), msg)
	pi_status_dismiss(&tab)
	testing.expect_value(t, pi_status_message(&tab), "")
	pi_status_reset()
	tab.reload.version = "1.4.0"
	testing.expect_value(t, pi_status_message(&tab), "")
	tab.reload.version = ""
	testing.expect_value(t, pi_status_message(&tab), "") // unknown: no bar
	tab.reload.version = "1.0.0"
	tab.status = .Exited
	testing.expect_value(t, pi_status_message(&tab), "")
	// the setup sheet's harness line
	defer claude_installed_probe = nil
	defer pi_installed_probe = nil
	pi_installed_probe = proc() -> bool {return true}
	claude_installed_probe = proc() -> bool {return false}
	state.reload.pi_version = "1.3.2"
	line := setup_claude_line()
	testing.expect(t, strings.contains(line, "pi 1.3.2 is older than 1.4.0"), line)
	state.reload.pi_version = "1.5.0"
	testing.expect(t, !strings.contains(setup_claude_line(), "older than"), setup_claude_line())
}

// Every pi start passes the integration first: a new chat, a restart of its tab (the same path
// restores and dead-tab restarts take), and Home (home_test checks its own arguments).
@(test)
pi_starts_with_the_integration :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := pin_dir(t)
	defer os.remove_all(dir)
	pi_integration_override = dir
	defer pi_integration_override = ""
	pi_integration_forget()
	defer pi_integration_forget()
	for _, x in terms {
		term_free(x)
		free(x)
	}
	clear(&terms)
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT},
	}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	argfile := fmt.tprintf("%s/args", dir)
	os.set_env("PI_DESK_CMD", fmt.tprintf(`printf '%%s\n' "$@" > %s.tmp; mv %s.tmp %s; exec sleep 30`, argfile, argfile, argfile))
	defer os.set_env("PI_DESK_CMD", "sleep 30")
	read_args :: proc(t: ^testing.T, path: string) -> string {
		for _ in 0 ..< 200 {
			if data, err := os.read_entire_file(path, context.temp_allocator); err == nil && len(data) > 0 {
				os.remove(path)
				return string(data)
			}
			time.sleep(20 * time.Millisecond)
		}
		testing.fail_now(t, "the fake pi wrote no arguments")
	}
	want := fmt.tprintf("-e\n%s/extensions/bridge\n-e\n%s/extensions/desk\n-e\n%s/extensions/guard\n--session-id\n", dir, dir, dir)
	run_command(Add_Project{cwd = "/tmp"}, {kind = .UI})
	sess := run_command(New_Chat{project_id = state.selected_project}, {kind = .UI}).created_id
	testing.expect(t, sess != 0)
	args := read_args(t, argfile)
	testing.expect(t, strings.has_prefix(args, want), args)
	testing.expect(t, !strings.contains(args, "--skill"), "the desk skill is Atlas's only")
	// its tab again (Restart, a restore, a dead tab's restart: start_restored_tabs)
	s := find_session(sess)
	tab := &s.tabs[0]
	if x := term_of(tab.id); x != nil {
		term_free(x)
		free(x)
		delete_key(&terms, tab.id)
	}
	testing.expect(t, start_pi_tab_again(s, tab))
	args = read_args(t, argfile)
	testing.expect(t, strings.has_prefix(args, fmt.tprintf("-e\n%s/extensions/bridge\n-e\n%s/extensions/desk\n", dir, dir)), args)
	for _, x in terms {
		term_free(x)
		free(x)
	}
	clear(&terms)
}

// The optional extensions are the user's: Set_Pi_Extension from the UI (or a saved choice coming
// back) turns one on or off; agents, scripts and pi tabs may not; a name the manifest does not list
// as optional is refused. Settings shows each with its line and default, and get_state the choices.
@(test)
pi_extensions_are_the_users :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	pin := pi_integration_for_test(t)
	defer pi_integration_test_done(pin)
	old := state.settings.pi_extensions
	defer state.settings.pi_extensions = old
	state.settings.pi_extensions = {}
	old_v := state.reload.pi_version
	defer state.reload.pi_version = old_v
	state.reload.pi_version = ""
	testing.expect(t, pi_extension_on("guard") && !pi_extension_on("extra"), "the manifest's defaults")
	not :: "not allowed for this caller"
	for c in ([]Caller{{kind = .Control}, {kind = .Script}, {kind = .Panel, tab_id = 1}}) {
		testing.expect_value(t, run_command(Set_Pi_Extension{name = "guard", on = false}, c).error, not)
	}
	testing.expect(t, pi_extension_on("guard"))
	testing.expect(t, !run_command(Set_Pi_Extension{name = "bridge", on = false}, {kind = .UI}).ok, "a required one")
	testing.expect(t, !run_command(Set_Pi_Extension{name = "nope", on = true}, {kind = .UI}).ok)
	testing.expect(t, !run_command(Set_Pi_Extension{name = "../x", on = true}, {kind = .UI}).ok)
	r := run_command(Set_Pi_Extension{name = "guard", on = false}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect(t, !pi_extension_on("guard"))
	testing.expect(t, run_command(Set_Pi_Extension{name = "extra", on = true}, {kind = .UI}).ok)
	testing.expect_value(t, strings.join(pi_integration_args(), " ", context.temp_allocator), fmt.tprintf("-e %s/extensions/bridge -e %s/extensions/desk -e %s/extensions/extra", pin, pin, pin))
	// the Settings tab's rows (pi installed only) and get_state
	defer pi_installed_probe = nil
	pi_installed_probe = proc() -> bool {return true}
	rows := make([dynamic]string, context.temp_allocator)
	for x in settings_file_rows() do if x.group == "pi-ext" do append(&rows, fmt.tprintf("%s|%s|%s", x.label, x.detail, x.button))
	testing.expect_value(t, strings.join(rows[:], "\n", context.temp_allocator), "extra|ON · an optional one (default off; pi tabs, not jobs)|Turn off\nguard|off · on by default (default on; pi tabs, not jobs)|Turn on")
	// jobs never load them (pi --mode json gets no -e)
	for a in job_argv("/bin/pi", "/s", "uuid", "", "", "/pre.md", "x", .Full) do testing.expect(t, a != "-e", "a job loads no pi extensions")
	testing.expect_value(t, settings_group_label("pi-ext", ""), "pi extensions (Deckhand's)")
	pi_installed_probe = proc() -> bool {return false}
	for x in settings_file_rows() do testing.expect(t, x.group != "pi-ext", "no pi: no pi extensions group")
	st := state_json()
	testing.expect_value(t, json_path(st, "settings.pi_extensions.guard"), "false")
	testing.expect_value(t, json_path(st, "settings.pi_extensions.extra"), "true")
}

// A choice applies at a tab's next start: each pi tab keeps which optional extensions it started
// with, and one that differs from the choices now is offered a restart ("pi extensions changed").
@(test)
pi_extension_change_offers_a_restart :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	pin := pi_integration_for_test(t)
	defer pi_integration_test_done(pin)
	old_s := state
	defer state = old_s
	state = State{}
	tab := Tab{id = 7171, kind = Pi_Tab{}, status = .Running, agent = .Idle}
	tab.reload.started = true
	tab.reload.extras = pi_integration_extras() // as start_pi records it
	s := Open_Session{id = 7170, cwd = "/tmp"}
	append(&s.tabs, tab)
	append(&state.open_sessions, s)
	t0 := &state.open_sessions[0].tabs[0]
	testing.expect(t, !reload_outdated(t0) && !restart_bar_shows())
	testing.expect(t, run_command(Set_Pi_Extension{name = "guard", on = false}, {kind = .UI}).ok)
	testing.expect(t, reload_outdated(t0), "started with guard, which is off now")
	testing.expect(t, restart_bar_shows())
	msg, can := reload_message(true)
	testing.expect_value(t, msg, "pi extensions changed — Restart 1 idle tab")
	testing.expect(t, can)
	// Later hides it; another change shows it again
	testing.expect(t, run_command(Pi_Reload_Later{restart = true}, {kind = .UI}).ok)
	testing.expect(t, !restart_bar_shows())
	testing.expect(t, run_command(Set_Pi_Extension{name = "extra", on = true}, {kind = .UI}).ok)
	testing.expect(t, restart_bar_shows())
	// back as it started: nothing to restart
	testing.expect(t, run_command(Set_Pi_Extension{name = "guard", on = true}, {kind = .UI}).ok)
	testing.expect(t, run_command(Set_Pi_Extension{name = "extra", on = false}, {kind = .UI}).ok)
	testing.expect(t, !reload_outdated(t0) && !restart_bar_shows())
}

// A saved choice comes back on the next start (persist), also for an extension this build lacks.
@(test)
pi_extension_choices_are_saved :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	old := state.settings.pi_extensions
	defer state.settings.pi_extensions = old
	state.settings.pi_extensions = {}
	testing.expect(t, run_command(Set_Pi_Extension{name = "notes", on = true}, {kind = .Internal}).ok)
	testing.expect(t, run_command(Set_Pi_Extension{name = "guardrails", on = false}, {kind = .Internal}).ok)
	text := workspace_json()
	testing.expect(t, strings.contains(text, `"pi_extensions":{"notes":true,"guardrails":false}`), text)
	state.settings.pi_extensions = {}
	testing.expect_value(t, workspace_restore(fmt.tprintf(`{{"v":%d,"settings":{{"pi_extensions":{{"notes":true,"guardrails":false}}}}}}`, WORKSPACE_VERSION)), "")
	testing.expect_value(t, len(state.settings.pi_extensions), 2)
	testing.expect(t, pi_extension_on("notes") && !pi_extension_on("guardrails"))
}

// Blockers name a shell's or timer's command and a subagent's task: the command log and events get
// only what kind and which id (as panel rows get only their count); the state keeps the text.
@(test)
pi_status_blockers_redacted_in_events :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	cmd := Pi_Status_Update{tab_id = 3, agent = .Idle, blockers = {"shell sh1: curl -H 'Authorization: Bearer abc' x", "timer wk2: check the deploy of secret-app", "subagent kit.worker", "+2 more · /shells"}}
	b := strings.builder_make(context.temp_allocator)
	write_command(&b, cmd, redact = true)
	got := strings.to_string(b)
	testing.expect(t, strings.contains(got, `"blockers":["shell sh1","timer wk2","subagent","<redacted>"]`), got)
	for leak in ([]string{"curl", "Bearer", "secret-app", "kit.worker", "more"}) do testing.expectf(t, !strings.contains(got, leak), "%s leaks: %s", leak, got)
	b2 := strings.builder_make(context.temp_allocator)
	write_command(&b2, cmd)
	testing.expect(t, strings.contains(strings.to_string(b2), "shell sh1: curl"), "unredacted for the state and the requester")
	// events (the command log and socket subscribers both write Command_Event through event_json)
	ev := event_json(Command_Event{request_id = 1, caller = {kind = .Panel, tab_id = 3}, version = 1, command = cmd, result = {ok = true}})
	testing.expect(t, strings.contains(ev, `"blockers":["shell sh1","timer wk2","subagent","<redacted>"]`), ev)
}
