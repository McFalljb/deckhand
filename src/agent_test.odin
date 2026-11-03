package main

// The built-in agent (agent.odin): Atlas's pi in a terminal tab — its
// arguments (--model, --append-system-prompt), its prompt file, the
// user-only model setting, unread and notifications from its bridge
// status, the model selector key (`./build.sh test`). Same rules as
// core_test.odin: shared global State, one thread, harmless processes.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
A_UI :: Caller{kind = .UI}

@(private = "file")
a_notes: [dynamic]string
@(private = "file")
a_active: bool

@(private = "file")
a_reset :: proc() -> string {
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
	clear(&a_notes)
	a_active = true
	agent_picker = {}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}, notify = proc(title, body: string) {append(&a_notes, strings.clone(body))}, window_active = proc() -> bool {return a_active}}
	os.set_env("SHELL", "/bin/sh")
	home_root = fmt.aprintf("%s/pd-atlas-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory_all(home_root)
	return home_root
}

@(private = "file")
a_done :: proc() {
	for _, x in terms do reader_stop_and_close(x)
	home_root = ""
}

// Polls a file until it has data (the fake pi writes it once started).
@(private = "file")
a_read :: proc(path: string, want := "") -> string {
	for _ in 0 ..< 200 {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil && len(data) > 0 && strings.contains(string(data), want) do return string(data)
		time.sleep(10 * time.Millisecond)
	}
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}

// A status from Atlas's bridge.
@(private = "file")
a_status :: proc(a: Agent_State, waiting := false) {
	tab := home_tab().id
	run_command(Pi_Status_Update{tab_id = tab, agent = a, waiting = waiting}, {kind = .Panel, tab_id = tab})
}

// Starts (or restarts) Atlas with a fake pi that writes its arguments to
// <dir>/args; returns them.
@(private = "file")
a_start :: proc(t: ^testing.T, dir: string) -> string {
	args := fmt.tprintf("%s/args", dir)
	os.remove(args)
	os.set_env("PI_DESK_CMD", fmt.tprintf(`printf '%%s\n' "$@" > '%s'; exec sleep 30`, args))
	if ht := home_tab(); ht != nil && ht.status == .Running do run_command(Tab_Exited{tab_id = ht.id})
	r := run_command(Set_Home{open = true}, A_UI)
	testing.expect(t, r.ok, r.error)
	return a_read(args)
}

@(test)
agent_argv_model_and_prompt :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	prompt := fmt.tprintf("%s/atlas/ATLAS.md", dir)
	// no setting: no --model (pi's default, or what its session remembers); the prompt always
	got := a_start(t, dir)
	testing.expect(t, !strings.contains(got, "--model"), got)
	testing.expect(t, strings.contains(got, fmt.tprintf("--append-system-prompt\n%s\n", prompt)), got)
	testing.expect(t, !strings.contains(got, "--mode"), got)
	// the user's own APPEND_SYSTEM.md (pi skips discovering it once a flag is given): passed first
	agent_dir := fmt.tprintf("%s/pi-agent", dir)
	os.make_directory_all(agent_dir)
	os.set_env("PI_CODING_AGENT_DIR", agent_dir)
	defer os.unset_env("PI_CODING_AGENT_DIR")
	_ = os.write_entire_file(fmt.tprintf("%s/APPEND_SYSTEM.md", agent_dir), transmute([]u8)string("be terse"))
	got = a_start(t, dir)
	testing.expect(t, strings.contains(got, fmt.tprintf("--append-system-prompt\n%s/APPEND_SYSTEM.md\n--append-system-prompt\n%s\n", agent_dir, prompt)), got)
	// the setting: --model on the next start (it changed since the last one)
	testing.expect(t, run_command(Set_Agent_Model{model = "opencode-go/muse-spark-1.2-contributor"}, A_UI).ok)
	got = a_start(t, dir)
	testing.expect(t, strings.contains(got, "--model\nopencode-go/muse-spark-1.2-contributor\n"), got)
	// applied only once pi reports (an unknown provider makes pi exit at once): until then --model again
	testing.expect_value(t, state.home_model, "")
	got = a_start(t, dir)
	testing.expect(t, strings.contains(got, "--model\nopencode-go/muse-spark-1.2-contributor\n"), got)
	a_status(.Idle)
	testing.expect_value(t, state.home_model, "opencode-go/muse-spark-1.2-contributor")
	// resumed with the same setting: no --model, so what the user picked in pi stays
	hs := home_session()
	_ = os.write_entire_file(fmt.tprintf("%s/2026-11-01T10-00-00-000Z_%s.jsonl", hs.session_dir, hs.pi_session_id), transmute([]u8)string(`{"type":"session","version":3,"id":"x"}` + "\n"))
	got = a_start(t, dir)
	testing.expect(t, strings.contains(got, "--session\n"), got)
	testing.expect(t, !strings.contains(got, "--model"), got)
	// changed again (with a thinking level): --model again, also on a resumed session
	testing.expect(t, run_command(Set_Agent_Model{model = "opencode-go/deepseek-v4.1-flash:high"}, A_UI).ok)
	got = a_start(t, dir)
	testing.expect(t, strings.contains(got, "--model\nopencode-go/deepseek-v4.1-flash:high\n"), got)
	a_status(.Idle)
	// saved with the workspace (setting and the last start's model) and restored
	ws := workspace_json()
	testing.expect(t, strings.contains(ws, `"agent_model":"opencode-go/deepseek-v4.1-flash:high"`), ws)
	testing.expect(t, strings.contains(ws, `"model_applied":"opencode-go/deepseek-v4.1-flash:high"`), ws)
}

@(test)
agent_prompt_file_made_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	path := fmt.tprintf("%s/atlas/ATLAS.md", dir)
	testing.expect_value(t, agent_prompt_ensure(), path)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), ATLAS_PROMPT_STARTER)
	testing.expect(t, strings.contains(string(data), "You are Atlas"), "starter")
	// the user's edit is never written over (also not at the next start)
	_ = os.write_entire_file(path, transmute([]u8)string("Call yourself Hal.\n"))
	testing.expect_value(t, agent_prompt_ensure(), path)
	a_start(t, dir)
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "Call yourself Hal.\n")
	// no data dir: no prompt file, no flag
	home_root = ""
	testing.expect_value(t, agent_prompt_ensure(), "")
	testing.expect_value(t, len(agent_extra_args(true)), 0)
	home_root = dir
}

// An unedited older starter becomes the current one (the old kept as
// ATLAS.md.bak-<date>); an edited file, or none, is left alone.
@(test)
agent_prompt_migrates_unedited_starter :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	path := fmt.tprintf("%s/atlas/ATLAS.md", dir)
	bak := fmt.tprintf("%s.bak-2026-11-01", path)
	read :: proc(p: string) -> string {
		data, _ := os.read_entire_file(p, context.temp_allocator)
		return string(data)
	}
	// none: nothing made
	testing.expect(t, !agent_prompt_migrate("2026-11-01"), "no file")
	testing.expect(t, !os.exists(path), "not made")
	// the old starter, byte for byte: replaced, the old one kept
	os.make_directory_all(fmt.tprintf("%s/atlas", dir))
	_ = os.write_entire_file(path, transmute([]u8)string(ATLAS_PROMPT_STARTER_V1))
	testing.expect(t, agent_prompt_migrate("2026-11-01"), "migrated")
	testing.expect_value(t, read(path), ATLAS_PROMPT_STARTER)
	testing.expect_value(t, read(bak), ATLAS_PROMPT_STARTER_V1)
	// the current starter: nothing to do (also at the next start)
	testing.expect(t, !agent_prompt_migrate("2026-11-02"), "current")
	testing.expect(t, !os.exists(fmt.tprintf("%s.bak-2026-11-02", path)), "no second backup")
	// edited (even one byte added to the old starter): left alone
	edited := strings.concatenate({ATLAS_PROMPT_STARTER_V1, "\nCall yourself Hal.\n"}, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)edited)
	testing.expect(t, !agent_prompt_migrate("2026-11-03"), "edited")
	testing.expect_value(t, read(path), edited)
	testing.expect(t, !os.exists(fmt.tprintf("%s.bak-2026-11-03", path)), "no backup of an edited file")
}

// The guide built into the binary is written to the data dir when it
// differs, and Atlas is told where it is.
@(test)
agent_guide_installed_and_passed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	path := fmt.tprintf("%s/atlas/GUIDE.md", dir)
	agent_guide_install()
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), ATLAS_GUIDE)
	_ = os.write_entire_file(path, transmute([]u8)string("stale"))
	agent_guide_install()
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), ATLAS_GUIDE)
	got := strings.join(agent_extra_args(true), "\n", context.temp_allocator)
	testing.expect(t, strings.contains(got, fmt.tprintf("--append-system-prompt\npi-desk user guide: %s", path)), got)
	testing.expect(t, strings.contains(ATLAS_PROMPT_STARTER, "pi-desk user guide:"), "the starter names the line")
}

@(test)
agent_model_is_users :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	a_start(t, dir)
	tab := home_tab().id
	not :: "not allowed for this caller"
	testing.expect_value(t, run_command(Set_Agent_Model{model = "x/y"}, {kind = .Control, tab_id = tab}).error, not) // Atlas itself
	testing.expect_value(t, run_command(Set_Agent_Model{model = "x/y"}, {kind = .Control}).error, not)
	testing.expect_value(t, run_command(Set_Agent_Model{model = "x/y"}, {kind = .Panel, tab_id = tab}).error, not)
	testing.expect_value(t, run_command(Agent_Model_Picker{}, {kind = .Control, tab_id = tab}).error, not)
	testing.expect_value(t, run_command(Set_Agent_Model{model = "nope"}, A_UI).error, `model must be "provider/id" (optionally ":thinking")`)
	testing.expect_value(t, run_command(Set_Agent_Model{model = "a/b c"}, A_UI).error, `model must be "provider/id" (optionally ":thinking")`)
	testing.expect(t, run_command(Set_Agent_Model{model = " opencode-go/muse-spark-1.2-contributor "}, A_UI).ok)
	testing.expect_value(t, state.settings.agent_model, "opencode-go/muse-spark-1.2-contributor")
	testing.expect_value(t, json_path(state_json(), "settings.agent_model"), "opencode-go/muse-spark-1.2-contributor")
	// the drawer shows the setting until pi's session names a model
	testing.expect_value(t, agent_model(), "opencode-go/muse-spark-1.2-contributor")
	testing.expect_value(t, agent_model_short(), "muse-spark-1.2-contributor")
	testing.expect(t, run_command(Set_Agent_Model{model = ""}, A_UI).ok)
	testing.expect_value(t, agent_model_short(), "")
}

// Unread and notifications come from Atlas's bridge status (pi.status).
@(test)
agent_unread_from_bridge_status :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	a_start(t, dir)
	tab := home_tab().id
	bridge := Caller{kind = .Panel, tab_id = tab}
	status :: proc(c: Caller, tab: u64, a: Agent_State, waiting := false) {
		run_command(Pi_Status_Update{tab_id = tab, agent = a, waiting = waiting}, c)
	}
	// drawer shown: a finished run is seen, not unread
	status(bridge, tab, .Working)
	status(bridge, tab, .Idle)
	testing.expect_value(t, state.agent.unread, 0)
	// shut: each finished run counts
	run_command(Set_Home{open = false}, A_UI)
	status(bridge, tab, .Working)
	status(bridge, tab, .Idle)
	status(bridge, tab, .Working)
	status(bridge, tab, .Error)
	testing.expect_value(t, state.agent.unread, 2)
	testing.expect_value(t, json_path(state_json(), "agent.unread"), "2")
	testing.expect_value(t, len(a_notes), 0) // the window is active: no OS notification
	// waiting for the user: the top bar's tint (needs_user)
	status(bridge, tab, .Idle, waiting = true)
	testing.expect(t, agent_needs_user())
	testing.expect_value(t, json_path(state_json(), "agent.needs_user"), "true")
	status(bridge, tab, .Idle)
	// in the background: finished and needs-you notify (the gap holds back a second "finished")
	a_active = false
	status(bridge, tab, .Working)
	status(bridge, tab, .Idle)
	status(bridge, tab, .Working)
	status(bridge, tab, .Idle)
	status(bridge, tab, .Idle, waiting = true)
	testing.expect_value(t, len(a_notes), 2)
	if len(a_notes) == 2 {
		testing.expect_value(t, a_notes[0], "Atlas finished")
		testing.expect_value(t, a_notes[1], "Atlas needs you")
	}
	run_command(Set_Notify{on = false}, A_UI)
	status(bridge, tab, .Working)
	status(bridge, tab, .Idle, waiting = true)
	testing.expect_value(t, len(a_notes), 2)
	// opening the drawer reads them
	run_command(Set_Home{open = true}, A_UI)
	testing.expect_value(t, state.agent.unread, 0)
}

// The Model button: pi's model selector key (Ctrl+L) into Atlas's own
// terminal; while pi starts (no status yet) it waits for pi's first status.
@(test)
agent_model_picker_key :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	out := fmt.tprintf("%s/stdin", dir)
	os.set_env("PI_DESK_CMD", fmt.tprintf("stty raw -echo; exec cat > '%s'", out))
	r := run_command(Agent_Model_Picker{}, A_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, state.home_open && state.focus_widget == "agent_input", "drawer shown with the keyboard")
	testing.expect(t, agent_picker.tab != 0, "waits for pi")
	time.sleep(200 * time.Millisecond) // stty ran
	run_command(Pi_Status_Update{tab_id = home_tab().id, agent = .Idle}, {kind = .Panel, tab_id = home_tab().id})
	testing.expect_value(t, agent_picker.tab, u64(0))
	testing.expect_value(t, a_read(out, PI_MODEL_SELECT_KEY), PI_MODEL_SELECT_KEY)
	// pi up: at once
	run_command(Set_Home{open = false}, A_UI)
	testing.expect(t, run_command(Agent_Model_Picker{}, A_UI).ok)
	testing.expect_value(t, a_read(out, "\x0c\x0c"), "\x0c\x0c")
	testing.expect(t, state.home_open)
	// a pi dialog is open: Ctrl+L would land in it
	a_status(.Idle, waiting = true)
	testing.expect_value(t, run_command(Agent_Model_Picker{}, A_UI).error, "Atlas is waiting for you")
	a_status(.Idle)
	time.sleep(100 * time.Millisecond)
	data, _ := os.read_entire_file(out, context.temp_allocator)
	testing.expect_value(t, string(data), "\x0c\x0c")
}

// A selector asked for while pi starts: bound to that tab, for a while.
@(test)
agent_model_picker_pending :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	out := fmt.tprintf("%s/stdin", dir)
	os.set_env("PI_DESK_CMD", fmt.tprintf("stty raw -echo; exec cat > '%s'", out))
	sent :: proc(path: string) -> string {
		time.sleep(100 * time.Millisecond)
		data, _ := os.read_entire_file(path, context.temp_allocator)
		return string(data)
	}
	// a dialog by the time pi reports: not sent, not kept
	testing.expect(t, run_command(Agent_Model_Picker{}, A_UI).ok)
	time.sleep(200 * time.Millisecond) // stty ran
	a_status(.Idle, waiting = true)
	testing.expect_value(t, agent_picker.tab, u64(0))
	a_status(.Idle)
	testing.expect_value(t, sent(out), "")
	// Atlas exits before it reports: dropped with it
	tab := home_tab().id
	run_command(Pi_Status_Update{tab_id = tab, agent = .Unknown}, {kind = .Internal})
	testing.expect(t, run_command(Agent_Model_Picker{}, A_UI).ok)
	testing.expect_value(t, agent_picker.tab, tab)
	run_command(Tab_Exited{tab_id = tab}, {kind = .Internal})
	testing.expect_value(t, agent_picker.tab, u64(0))
	// restarted: asked again, then a reload (pi starts over) drops it too
	testing.expect(t, run_command(Set_Home{open = true}, A_UI).ok)
	testing.expect(t, run_command(Agent_Model_Picker{}, A_UI).ok)
	testing.expect(t, agent_picker.tab == home_tab().id)
	run_command(Pi_Reload{tab_id = home_tab().id}, A_UI)
	testing.expect_value(t, agent_picker.tab, u64(0))
	// past the deadline: a late status sends nothing
	testing.expect(t, run_command(Agent_Model_Picker{}, A_UI).ok)
	agent_picker.deadline = time.tick_now()
	time.sleep(10 * time.Millisecond)
	a_status(.Idle)
	testing.expect_value(t, agent_picker.tab, u64(0))
	testing.expect_value(t, sent(out), "")
	// no bridge (pi never reports) for longer than that: an error, not a wait
	run_command(Pi_Status_Update{tab_id = home_tab().id, agent = .Unknown}, {kind = .Internal})
	agent_started = time.tick_add(time.tick_now(), -PICKER_WAIT - time.Second)
	r := run_command(Agent_Model_Picker{}, A_UI)
	testing.expect(t, !r.ok && strings.contains(r.error, "no status"), r.error)
	testing.expect_value(t, agent_picker.tab, u64(0))
}

// Only the user moves the keyboard into Atlas's terminal.
@(test)
agent_keyboard_is_users :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	a_start(t, dir)
	tab := home_tab().id
	run_command(Set_Focus{widget = ""}, A_UI)
	want :: "only the user moves the keyboard into the agent's terminal"
	testing.expect_value(t, run_command(Set_Focus{widget = "agent_input"}, {kind = .Control, tab_id = tab}).error, want)
	testing.expect_value(t, run_command(Set_Focus{widget = "agent_input"}, {kind = .Control}).error, want)
	testing.expect_value(t, run_command(Set_Focus{widget = "agent_input"}, {kind = .Script}).error, want)
	testing.expect_value(t, run_command(Set_Focus{widget = "agent_input"}, {kind = .Panel, tab_id = tab}).error, "not allowed for this caller") // no focus for pi tabs at all
	testing.expect_value(t, state.focus_widget, "")
	// a control script may show the drawer, but the keyboard stays where it is
	run_command(Set_Home{open = false}, A_UI)
	testing.expect(t, run_command(Set_Home{open = true}, {kind = .Script}).ok)
	testing.expect_value(t, state.focus_widget, "")
	testing.expect(t, run_command(Set_Focus{widget = "agent_input"}, A_UI).ok)
}

// The model pi-desk shows: the last model_change of Atlas's session file.
@(test)
agent_model_from_session :: proc(t: ^testing.T) {
	text := `{"type":"session","version":3,"id":"a"}
{"type":"model_change","id":"1","provider":"opencode-go","modelId":"deepseek-v4.1-flash"}
{"type":"message","message":{"role":"user","content":"\"type\":\"model_change\" in text"}}
{"type":"model_change","id":"2","provider":"anthropic","modelId":"claude-x"}
{"type":"message","message":{"role":"assistant","content":"hi"}}
`
	testing.expect_value(t, last_model_change(text), "anthropic/claude-x")
	testing.expect_value(t, last_model_change(`{"type":"session"}`), "")
	testing.expect_value(t, last_model_change(""), "")
}

// Saving ATLAS.md offers to reload Atlas (pi_reload of Atlas's tab, the
// hot-reload bar), once its bridge can take a reload; only Atlas's tab.
@(test)
agent_prompt_save_offers_restart :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	reload_watch_reset()
	defer reload_watch_reset()
	a_start(t, dir)
	tab := home_tab().id
	testing.expect_value(t, atlas_reloadable(), u64(0)) // pi has not reported yet
	run_command(Pi_Status_Update{tab_id = tab, agent = .Idle}, {kind = .Panel, tab_id = tab})
	testing.expect_value(t, atlas_reloadable(), tab)
	settings_after_save(42, agent_prompt_ensure())
	testing.expect(t, reload_flush(), "the save shows the bar at once")
	testing.expect(t, home_tab().reload.stale, "Atlas reads its prompt")
	msg, can := reload_message(false)
	testing.expect(t, can && strings.has_prefix(msg, "Atlas's prompt changed — Reload 1 idle tab"), msg)
}

// The notes folder's copy (docs/ATLAS.md §8: frontmatter + the prompt) of an
// unedited older starter is updated too, also when the notes folder is
// restored after the startup migration; its frontmatter stays.
@(test)
agent_prompt_migrates_notes_copy :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	notes := fmt.tprintf("%s/notes", dir)
	os.make_directory_all(fmt.tprintf("%s/atlas", notes))
	np := fmt.tprintf("%s/atlas/ATLAS.md", notes)
	front := "---\ntype: atlas\nproject: atlas\ndate: 2026-10-01\nstatus: active\nsummary: Atlas's prompt\ntags: [atlas]\nupdated_by: atlas\n---\n"
	_ = os.write_entire_file(np, transmute([]u8)strings.concatenate({front, ATLAS_PROMPT_STARTER_V1}, context.temp_allocator))
	saved := state.settings.home_dir
	defer state.settings.home_dir = saved
	state.settings.home_dir = ""
	// the notes folder comes back with the workspace, after the startup migration
	testing.expect(t, run_command(Set_Home_Dir{path = notes}, {kind = .UI}).ok)
	data, _ := os.read_entire_file(np, context.temp_allocator)
	testing.expect_value(t, string(data), strings.concatenate({front, ATLAS_PROMPT_STARTER}, context.temp_allocator))
	// a data-dir copy that is an old starter is not copied over as one
	os.remove(np)
	dp := fmt.tprintf("%s/atlas/ATLAS.md", dir)
	os.make_directory_all(fmt.tprintf("%s/atlas", dir))
	_ = os.write_entire_file(dp, transmute([]u8)string(ATLAS_PROMPT_STARTER_V1))
	testing.expect_value(t, agent_prompt_ensure(), np)
	data, _ = os.read_entire_file(np, context.temp_allocator)
	testing.expect(t, strings.has_suffix(string(data), ATLAS_PROMPT_STARTER), "the current starter, not the old one")
}

// Send to Atlas while its pi starts: text that cannot go in (a dialog, the
// model selector opening, no bracketed paste) is said in the bell and kept
// on the clipboard, never dropped without a word; the selector's key and the
// text never share pi's input.
@(test)
agent_send_while_starting_says_why :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	@(static) clip: string
	clip = ""
	platform.set_clipboard = proc(s: string) {clip = strings.clone(s)}
	out := fmt.tprintf("%s/stdin", dir)
	os.set_env("PI_DESK_CMD", fmt.tprintf("stty raw -echo; exec cat > '%s'", out))
	sent :: proc(path: string) -> string {
		time.sleep(100 * time.Millisecond)
		data, _ := os.read_entire_file(path, context.temp_allocator)
		return string(data)
	}
	said :: proc() -> int {
		n := 0
		for x in state.notices.items do if strings.contains(x.place, "Send to") do n += 1
		return n
	}
	// a dialog by the time pi reports
	testing.expect(t, agent_send("one\n", A_UI).ok, "waits for pi")
	time.sleep(200 * time.Millisecond) // stty ran
	a_status(.Idle, waiting = true)
	testing.expect_value(t, said(), 1)
	testing.expect_value(t, clip, "one\n")
	a_status(.Idle)
	testing.expect_value(t, sent(out), "")
	// the model selector opens at the same status: the text stays out of it
	tab := home_tab().id
	run_command(Pi_Status_Update{tab_id = tab, agent = .Unknown}, {kind = .Internal})
	testing.expect(t, run_command(Agent_Model_Picker{}, A_UI).ok)
	testing.expect(t, agent_send("two\n", A_UI).ok, "waits for pi")
	a_status(.Idle)
	testing.expect_value(t, sent(out), PI_MODEL_SELECT_KEY)
	testing.expect_value(t, said(), 2)
	testing.expect_value(t, clip, "two\n")
	// pi's input takes no bracketed paste (this fake pi): it waits a little for
	// pi's terminal to turn it on (its output may come after the status), then says so
	run_command(Pi_Status_Update{tab_id = tab, agent = .Unknown}, {kind = .Internal})
	testing.expect(t, agent_send("three\n", A_UI).ok, "waits for pi")
	a_status(.Idle)
	testing.expect_value(t, said(), 2)
	agent_pending_tick()
	testing.expect_value(t, said(), 2)
	agent_pending_tick(time.tick_add(time.tick_now(), PASTE_WAIT + time.Second))
	testing.expect_value(t, said(), 3)
	testing.expect_value(t, clip, "three\n")
	testing.expect_value(t, sent(out), PI_MODEL_SELECT_KEY)
}

// Send to Atlas text waiting for pi: said at once when pi exits (or is
// stopped), or once it waited too long; a later start never touches the
// clipboard.
@(test)
agent_send_pending_dropped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	@(static) clip: string
	clip = ""
	platform.set_clipboard = proc(s: string) {clip = strings.clone(s)}
	out := fmt.tprintf("%s/stdin", dir)
	os.set_env("PI_DESK_CMD", fmt.tprintf("stty raw -echo; exec cat > '%s'", out))
	said :: proc() -> int {
		n := 0
		for x in state.notices.items do if strings.contains(x.place, "Send to") do n += 1
		return n
	}
	// pi exits right after Send: said now
	testing.expect(t, agent_send("one\n", A_UI).ok, "waits for pi")
	tab := home_tab().id
	run_command(Tab_Exited{tab_id = tab}, {kind = .Internal})
	testing.expect_value(t, said(), 1)
	testing.expect_value(t, clip, "one\n")
	// started again and reporting: the old text is gone, the clipboard stays
	clip = ""
	testing.expect(t, run_command(Set_Home{open = true}, A_UI).ok)
	time.sleep(200 * time.Millisecond)
	a_status(.Idle)
	testing.expect_value(t, clip, "")
	testing.expect_value(t, said(), 1)
	// waited past its deadline: the tick says so, and a late status does nothing
	run_command(Pi_Status_Update{tab_id = home_tab().id, agent = .Unknown}, {kind = .Internal})
	testing.expect(t, agent_send("two\n", A_UI).ok, "waits for pi")
	agent_pending_tick(time.tick_add(time.tick_now(), PICKER_WAIT + time.Second))
	testing.expect_value(t, said(), 2)
	testing.expect_value(t, clip, "two\n")
	clip = ""
	a_status(.Idle)
	testing.expect_value(t, clip, "")
	testing.expect_value(t, said(), 2)
}

// Send to Atlas while its pi starts, when pi's first status comes before
// its terminal turns bracketed paste on (the bridge's socket and the pty are
// different ways): the text waits for the paste mode and goes in, nothing
// said (the menu's Send to Atlas with Atlas not running yet).
@(test)
agent_send_waits_for_paste_mode :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	@(static) clip: string
	clip = ""
	platform.set_clipboard = proc(s: string) {clip = strings.clone(s)}
	out := fmt.tprintf("%s/stdin", dir)
	os.set_env("PI_DESK_CMD", fmt.tprintf(`stty raw -echo; sleep 0.3; printf '\033[?2004h'; exec cat > '%s'`, out))
	testing.expect(t, agent_send("four\n", A_UI).ok, "waits for pi")
	a_status(.Idle) // before the paste mode is on
	testing.expect_value(t, len(state.notices.items), 0)
	ht := home_tab()
	tm := term_of(ht.id)
	for _ in 0 ..< 200 {
		pump_all()
		agent_pending_tick()
		if tm != nil && mode_on(tm, 2004) do break
		time.sleep(10 * time.Millisecond)
	}
	agent_pending_tick()
	got := a_read(out, "four")
	testing.expectf(t, strings.contains(got, "\x1b[200~four\n\x1b[201~"), "pasted: %q", got)
	testing.expect_value(t, len(state.notices.items), 0)
	testing.expect_value(t, clip, "")
}

// Send to Atlas again while the first text waits for pi's paste mode (or
// just after Atlas's first status, before its terminal turned it on): the
// new text waits too, the old one is said ("sent again before it went in");
// the new one goes in once the mode is on.
@(test)
agent_send_again_while_waiting_for_paste_mode :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	@(static) clip: string
	clip = ""
	platform.set_clipboard = proc(s: string) {clip = strings.clone(s)}
	out := fmt.tprintf("%s/stdin", dir)
	os.set_env("PI_DESK_CMD", fmt.tprintf(`stty raw -echo; sleep 0.5; printf '\033[?2004h'; exec cat > '%s'`, out))
	testing.expect(t, agent_send("one\n", A_UI).ok, "waits for pi")
	a_status(.Idle) // before the paste mode is on
	r := agent_send("two\n", A_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(state.notices.items), 1) // "one": sent again
	testing.expect_value(t, clip, "one\n")
	// pi's terminal turns paste mode on: "two" goes in, "one" never does
	tm := term_of(home_tab().id)
	for _ in 0 ..< 200 {
		pump_all()
		agent_pending_tick()
		if tm != nil && mode_on(tm, 2004) do break
		time.sleep(10 * time.Millisecond)
	}
	agent_pending_tick()
	got := a_read(out, "two")
	testing.expectf(t, strings.contains(got, "\x1b[200~two\n\x1b[201~") && !strings.contains(got, "one"), "pasted: %q", got)
	testing.expect_value(t, len(state.notices.items), 1)
}

// A status that comes while the text waits for pi's paste mode keeps its
// deadline: statuses every second never make it wait for ever.
@(test)
agent_send_paste_wait_deadline_holds :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := a_reset()
	defer a_done()
	platform.set_clipboard = proc(s: string) {}
	out := fmt.tprintf("%s/stdin", dir)
	os.set_env("PI_DESK_CMD", fmt.tprintf(`stty raw -echo; exec cat > '%s'`, out)) // never turns paste mode on
	testing.expect(t, agent_send("one\n", A_UI).ok, "waits for pi")
	t0 := time.tick_now()
	a_status(.Idle)
	time.sleep(time.Second)
	a_status(.Idle) // again, a second later
	agent_pending_tick(time.tick_add(t0, PASTE_WAIT + 500 * time.Millisecond))
	testing.expect_value(t, len(state.notices.items), 1)
}
