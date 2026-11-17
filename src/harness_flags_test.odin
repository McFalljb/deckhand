package main

// Flags for harness tabs at the window (ui_flags.odin, core/harness_flags.odin; docs/GUIDE.md
// "Flags for a tab"): the defaults in Settings go first in argv, the tab's own after them and only
// those are saved; pi's new session takes them too; the "… with flags…" entries open the palette's
// one-line field prefilled with the last flags, split shell-style, and a refused flag shows the
// core's reason; the Settings field sets the defaults.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core"
import gh "ghostty"

@(private = "file")
HF_UI :: core.Caller{kind = .UI}

@(private = "file")
hf_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/deckhand-hf-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r)) : d
}

// A fresh state; pi's and claude's argv go to <argf>.pi and <argf>.claude at each start.
@(private = "file")
hf_reset :: proc() -> (runtime.Allocator, string) {
	context.allocator = runtime.heap_allocator()
	for _, t in core.terms {
		core.term_free(t)
		free(t)
	}
	clear(&core.terms)
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT}}
	core.persist = {}
	core.platform = {quit = proc() {}}
	win_os = {set_clipboard = proc(s: string) {}}
	for &f in flags_last {
		delete(f)
		f = ""
	}
	tf_set(&palette.field, "")
	os.set_env("SHELL", "/bin/sh")
	argf := fmt.aprintf("%s/argv", hf_dir("argv"))
	os.set_env("DECKHAND_CMD", fmt.tprintf(`printf '%%s\n' "$@" > '%s.pi.tmp'; mv '%s.pi.tmp' '%s.pi'; exec sleep 30`, argf, argf, argf))
	os.set_env("DECKHAND_CLAUDE_CMD", fmt.tprintf(`printf '%%s\n' "$@" > '%s.claude.tmp'; mv '%s.claude.tmp' '%s.claude'; exec sleep 30`, argf, argf, argf))
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	os.set_env("CLAUDE_CONFIG_DIR", fmt.tprintf("%s/deckhand-hf-no-claude-config", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")))
	core.harness_found[.Claude] = .Yes
	core.harness_found[.Codex] = .No
	core.claude_cli_override = "/tmp/deckhand-hf-cli"
	return runtime.heap_allocator(), argf
}

@(private = "file")
hf_done :: proc() {
	core.claude_cli_override = ""
	core.harness_found[.Codex] = .Unknown
	for &f in flags_last {
		delete(f)
		f = ""
	}
}

// The argv the next start of `which` ("pi", "claude") writes; run starts it.
@(private = "file")
hf_argv :: proc(argf, which: string, run: proc(rawptr) -> core.Result, data: rawptr) -> (core.Result, string) {
	f := fmt.tprintf("%s.%s", argf, which)
	os.remove(f)
	r := run(data)
	core.inbox_drain()
	if !r.ok do return r, ""
	for _ in 0 ..< 200 {
		if b, err := os.read_entire_file(f, context.temp_allocator); err == nil && len(b) > 0 do return r, strings.join(strings.split(strings.trim_right(string(b), "\n"), "\n", context.temp_allocator), " ", context.temp_allocator)
		time.sleep(20 * time.Millisecond)
	}
	return r, ""
}

@(private = "file")
hf_args_of :: proc(tab: u64) -> string {
	_, _, ct := core.claude_tab_of(tab)
	return ct != nil ? strings.join(ct.args, " ", context.temp_allocator) : "<none>"
}

// Claude Code: the defaults (Settings) before the tab's own flags, never saved into the tab; an
// agent's start gets neither.
@(test)
harness_flags_claude_start :: proc(t: ^testing.T) {
	alloc, argf := hf_reset()
	context.allocator = alloc
	defer hf_done()
	pid := core.run_command(core.Add_Project{cwd = hf_dir("claude")}, HF_UI).created_id
	sess := core.run_command(core.New_Chat{project_id = pid}, HF_UI).created_id
	testing.expect(t, core.run_command(core.Set_Harness_Flags{harness = .Claude, flags = `--model sonnet --add-dir '/tmp/a b'`}, HF_UI).ok)
	Start :: struct {
		cmd:    core.Command,
		caller: core.Caller,
	}
	run :: proc(p: rawptr) -> core.Result {s := (^Start)(p); return core.run_command(s.cmd, s.caller)}
	st := Start{core.New_Claude_Tab{session = sess, args = {"--model", "opus"}, harness = .Claude}, HF_UI}
	r, argv := hf_argv(argf, "claude", run, &st)
	testing.expect(t, r.ok, r.error)
	testing.expectf(t, strings.contains(argv, "--add-dir /tmp/a b --model opus") && !strings.contains(argv, "sonnet"), "defaults first, the tab's after: %q", argv)
	testing.expect_value(t, hf_args_of(r.created_id), "--model opus") // only the tab's own are saved
	st = Start{core.New_Claude_Tab{session = sess, harness = .Claude}, core.Caller{kind = .Control}}
	r, argv = hf_argv(argf, "claude", run, &st)
	testing.expect(t, r.ok, r.error)
	testing.expectf(t, argv != "" && !strings.contains(argv, "--add-dir"), "an agent's start: no defaults: %q", argv)
}

// pi: a new session takes the user's flags, after the defaults; a script's start gets no defaults.
@(test)
harness_flags_pi_start :: proc(t: ^testing.T) {
	alloc, argf := hf_reset()
	context.allocator = alloc
	defer hf_done()
	pid := core.run_command(core.Add_Project{cwd = hf_dir("pi")}, HF_UI).created_id
	testing.expect(t, core.run_command(core.Set_Harness_Flags{harness = .Pi, flags = "--offline --model haiku"}, HF_UI).ok)
	Start :: struct {
		cmd:    core.Command,
		caller: core.Caller,
	}
	run :: proc(p: rawptr) -> core.Result {s := (^Start)(p); return core.run_command(s.cmd, s.caller)}
	st := Start{core.New_Chat{project_id = pid, args = {"--model", "sonnet", "--thinking", "high"}}, HF_UI}
	r, argv := hf_argv(argf, "pi", run, &st)
	testing.expect(t, r.ok, r.error)
	testing.expectf(t, strings.contains(argv, "--session-id") && strings.has_suffix(argv, "--offline --model sonnet --thinking high") && !strings.contains(argv, "haiku"), "%q", argv)
	st = Start{core.New_Chat{project_id = pid}, core.Caller{kind = .Script}}
	r, argv = hf_argv(argf, "pi", run, &st)
	testing.expect(t, r.ok, r.error)
	testing.expectf(t, argv != "" && !strings.contains(argv, "--offline"), "a script's: %q", argv)
}

// The entries: the tab strip's "+" lists "New Claude tab with flags…" and "New session with
// flags…"; the palette's field is prefilled with the last flags used from this window,
// split shell-style into the command's args; a refused flag shows the core's reason and starts
// nothing; the harness picker's "With flags…" lists each harness.
@(test)
harness_flags_entries :: proc(t: ^testing.T) {
	alloc, _ := hf_reset()
	context.allocator = alloc
	defer hf_done()
	defer core.run_command(core.Set_Focus{""}, HF_UI)
	dir := hf_dir("entries")
	pid := core.run_command(core.Add_Project{cwd = dir}, HF_UI).created_id
	core.run_command(core.Select_Project{pid}, HF_UI)
	sess := core.run_command(core.New_Chat{project_id = pid}, HF_UI).created_id
	testing.expect(t, sess != 0)
	menu_open(Menu_New{}, {0, 0})
	labels := make([dynamic]string, context.temp_allocator)
	for it in menu_items() do append(&labels, it.label)
	menu_close()
	joined := strings.join(labels[:], "|", context.temp_allocator)
	testing.expectf(t, strings.contains(joined, "New Claude tab with flags…") && strings.contains(joined, "New session with flags…"), "%s", joined)
	action_run("new_claude_tab_flags")
	core.inbox_drain()
	testing.expect(t, palette_is_open(), "the palette asks")
	_, is := palette.flags_for.(core.New_Claude_Tab)
	testing.expect(t, is, "for a Claude tab")
	testing.expect_value(t, tf_text(&palette.field), "") // nothing used yet
	tf_set(&palette.field, `--model sonnet --append-system-prompt "be brief"`)
	rs := palette_results()
	testing.expect(t, len(rs) == 1 && rs[0].why == "", "one row to start")
	n := len(core.find_session(sess).tabs)
	if len(rs) == 1 do palette_run(rs[0])
	core.inbox_drain()
	s := core.find_session(sess)
	testing.expect_value(t, len(s.tabs), n + 1)
	if len(s.tabs) == n + 1 do testing.expect_value(t, hf_args_of(s.tabs[n].id), "--model sonnet --append-system-prompt be brief")
	testing.expect_value(t, flags_last[.Claude], `--model sonnet --append-system-prompt "be brief"`)
	// next time: this run's last
	action_run("new_claude_tab_flags")
	core.inbox_drain()
	testing.expect_value(t, tf_text(&palette.field), `--model sonnet --append-system-prompt "be brief"`)
	// refused: the core's reason, nothing starts
	tf_set(&palette.field, "--resume abc")
	rs = palette_results()
	testing.expect(t, len(rs) == 1 && rs[0].why == "--resume is Deckhand's to set", "the core's reason")
	tf_set(&palette.field, `--model "opus`)
	rs = palette_results()
	testing.expect(t, len(rs) == 1 && strings.contains(rs[0].why, "quote"), "an open quote")
	if len(rs) == 1 do palette_run(rs[0])
	core.inbox_drain()
	testing.expect_value(t, len(core.find_session(sess).tabs), n + 1)
	core.run_command(core.Set_Focus{""}, HF_UI)
	// the picker: With flags…, then a row per harness that takes flags here
	new_session_ui(pid, flags = true)
	rows := make([dynamic]string, context.temp_allocator)
	for it in menu_items() do append(&rows, it.label)
	joined = strings.join(rows[:], "|", context.temp_allocator)
	testing.expectf(t, strings.contains(joined, "pi with flags…") && strings.contains(joined, "Claude Code with flags…"), "%s", joined)
	for it, i in menu_items() do if it.label == "pi with flags…" {
		menu_run(i)
		break
	}
	core.inbox_drain()
	_, is = palette.flags_for.(core.New_Chat)
	testing.expect(t, palette_is_open() && is, "pi's field")
	tf_set(&palette.field, "--model sonnet")
	rs = palette_results()
	before := len(state.open_sessions)
	if len(rs) == 1 do palette_run(rs[0])
	core.inbox_drain()
	testing.expect_value(t, len(state.open_sessions), before + 1)
	testing.expect_value(t, flags_last[.Pi], "--model sonnet")
}

// Settings › Coding agents › Default flags…: the page's field, the core's reason when refused.
@(test)
harness_flags_settings_field :: proc(t: ^testing.T) {
	alloc, _ := hf_reset()
	context.allocator = alloc
	defer hf_done()
	defer settings_page_off()
	core.run_command(core.Set_Harness_Flags{harness = .Codex, flags = "-m o3"}, HF_UI)
	action_run("codex_default_flags")
	core.inbox_drain()
	testing.expect(t, spage.edit.kind == .Harness_Flags, "its field")
	testing.expect_value(t, tf_text(&spage.edit.field), "-m o3")
	tf_set(&spage.edit.field, "--no-daemon")
	sp_edit_commit()
	testing.expect_value(t, spage.edit.err, core.codex_args_check({"--no-daemon"}))
	testing.expect_value(t, state.settings.harness_flags[.Codex], "-m o3")
	tf_set(&spage.edit.field, "--search -m gpt-5")
	sp_edit_commit()
	testing.expect_value(t, state.settings.harness_flags[.Codex], "--search -m gpt-5")
	testing.expect(t, spage.edit.kind == .None, "closed")
}

// Flags that turn Claude Code's hooks off (`--settings '{"disableAllHooks":true}'`: allowed, as the
// user's own settings.json may do the same) leave the tab without Deckhand's hooks; it gets the
// bar every hook-less tab gets, which says so.
@(test)
harness_flags_hooks_off_bar :: proc(t: ^testing.T) {
	alloc, _ := hf_reset()
	context.allocator = alloc
	defer hf_done()
	pid := core.run_command(core.Add_Project{cwd = hf_dir("hooksoff")}, HF_UI).created_id
	sess := core.run_command(core.New_Chat{project_id = pid}, HF_UI).created_id
	r := core.run_command(core.New_Claude_Tab{session = sess, args = {"--settings", `{"disableAllHooks":true}`}, harness = .Claude}, HF_UI)
	testing.expect(t, r.ok, r.error)
	_, tab, _ := core.find_tab(r.created_id)
	if tab == nil do return
	now := time.tick_add(time.tick_now(), -(core.CLAUDE_HOOKS_GRACE + 5 * time.Second))
	core.claude_status_tick(now)
	if tm := core.term_of(r.created_id); tm != nil { 	// Claude's prompt is up (bracketed paste on)
		msg := "\x1b[?2004h"
		gh.terminal_vt_write(tm.gt, raw_data(msg), len(msg))
	}
	core.claude_status_tick(now)
	later := time.tick_now()
	core.claude_status_tick(later)
	testing.expect(t, core.claude_hooks_silent(tab, later), "no hook ever reports")
	bar := core.claude_status_message(tab, later)
	testing.expectf(t, strings.contains(bar, "hooks aren't running") && strings.contains(bar, "--settings"), "%q", bar)
}
