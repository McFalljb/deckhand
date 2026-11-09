package main

// General setups (`./build.sh test`): Deckhand without pi or without Claude Code (harness.odin),
// the one "New session" picker, pi's sessions under PI_CODING_AGENT_DIR, non-POSIX login shells,
// and versions read from other install layouts (nix, mise, bun, pnpm). Same rules as core_test.odin:
// shared global State, one thread, `sleep` standing in for pi and claude; never a real pi or claude.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
H_UI :: core.Caller{kind = .UI}

@(private = "file")
h_reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in core.terms {
		core.term_free(t)
		free(t)
	}
	clear(&core.terms)
	core.inbox_drain()
	if menu.open do menu_close()
	state^ = core.State {
		layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT},
	}
	core.platform = {quit = proc() {}}
	win_os = {set_clipboard = proc(s: string) {}}
	toast_clear()
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	os.set_env("DECKHAND_CLAUDE_CMD", "sleep 30")
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	// a fresh HOME and Claude Code's default account (earlier tests leave theirs, maybe deleted)
	os.set_env("HOME", h_dir("home"))
	os.unset_env("CLAUDE_CONFIG_DIR")
	core.claude_accounts_refresh()
	return runtime.heap_allocator()
}

@(private = "file")
h_done :: proc() {
	core.inbox_drain()
	if menu.open do menu_close()
	for _, t in core.terms do core.reader_stop_and_close(t)
	core.pi_installed_probe = nil
	core.claude_installed_probe = nil
	toast_clear()
}

@(private = "file")
h_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/deckhand-hs-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	return d
}

@(private = "file")
h_write :: proc(path, text: string, exec := false) {
	_ = os.write_entire_file(path, transmute([]u8)text)
	if exec do os.change_mode(path, os.perm_number(0o755))
}

@(private = "file")
h_both :: proc() {
	core.pi_installed_probe = proc() -> bool {return true}
	core.claude_installed_probe = proc() -> bool {return true}
}

// ---- is pi installed? (looked for, never run) ----

@(test)
pi_detect_places :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	base := h_dir("pidetect")
	fake := "#!/bin/sh\nexit 1\n" // never run
	onpath := fmt.tprintf("%s/bin", base)
	os.make_directory_all(onpath)
	testing.expect(t, !core.pi_detect(onpath, "", ""), "an empty folder")
	h_write(fmt.tprintf("%s/pi", onpath), fake)
	testing.expect(t, !core.pi_detect(onpath, "", ""), "not executable")
	os.change_mode(fmt.tprintf("%s/pi", onpath), os.perm_number(0o755))
	testing.expect(t, core.pi_detect(fmt.tprintf("/nowhere:%s", onpath), "", ""), "on PATH")
	testing.expect(t, !core.pi_detect("bin", "", ""), "a relative PATH entry is never looked in")
	// pi's managed install: $PI_CODING_AGENT_DIR/bin, else ~/.pi/agent/bin
	agent := fmt.tprintf("%s/agent", base)
	os.make_directory_all(fmt.tprintf("%s/bin", agent))
	h_write(fmt.tprintf("%s/bin/pi", agent), fake, exec = true)
	testing.expect(t, core.pi_detect("/usr/bin", "", agent), "in $PI_CODING_AGENT_DIR/bin")
	home := fmt.tprintf("%s/home", base)
	os.make_directory_all(fmt.tprintf("%s/.pi/agent/bin", home))
	testing.expect(t, !core.pi_detect("/usr/bin", home, ""), "nothing in ~/.pi/agent/bin yet")
	h_write(fmt.tprintf("%s/.pi/agent/bin/pi", home), fake, exec = true)
	testing.expect(t, core.pi_detect("/usr/bin", home, ""), "in ~/.pi/agent/bin")
	testing.expect(t, !core.pi_detect("/usr/bin", "relative", "agent"), "relative folders are never looked in")
	// DECKHAND_CMD replaces pi: it counts as installed (scenes, benchmarks)
	os.set_env("DECKHAND_CMD", "sleep 30")
	testing.expect(t, core.pi_installed(), "DECKHAND_CMD stands in for pi")
}

// ---- the one "New session": a picker of the installed harnesses ----

@(test)
new_session_choices_installed :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	dir := h_dir("choices")
	pid := core.run_command(core.Add_Project{cwd = dir}, H_UI).created_id
	p := core.find_project(pid)
	labels :: proc(items: []core.Menu_Item) -> string {
		b := strings.builder_make(context.temp_allocator)
		for it, i in items {
			if i > 0 do strings.write_byte(&b, '|')
			strings.write_string(&b, it.label)
		}
		return strings.to_string(b)
	}
	// both: pi first (the default before anything was used), then Claude Code; numbered
	h_both()
	items := core.new_session_choices(p, "")
	testing.expect_value(t, labels(items), "pi|Claude Code")
	testing.expect_value(t, items[0].keys, "1")
	testing.expect_value(t, items[1].keys, "2")
	testing.expect_value(t, items[0].icon, core.harness_icon(.Pi))
	testing.expect_value(t, items[1].icon, core.harness_icon(.Claude))
	_, is_pi := items[0].cmd.(core.New_Chat)
	testing.expect(t, is_pi, "pi: a new pi session")
	_, is_cl := items[1].cmd.(core.New_Claude_Session)
	testing.expect(t, is_cl, "Claude Code: a Claude-only session")
	// the last used goes first, so Enter repeats it
	state.settings.last_harness = .Claude
	testing.expect_value(t, labels(core.new_session_choices(p, "")), "Claude Code|pi")
	state.settings.last_harness = .Pi
	// one harness: only it
	core.pi_installed_probe = proc() -> bool {return false}
	testing.expect_value(t, labels(core.new_session_choices(p, "")), "Claude Code")
	core.pi_installed_probe = proc() -> bool {return true}
	core.claude_installed_probe = proc() -> bool {return false}
	testing.expect_value(t, labels(core.new_session_choices(p, "")), "pi")
	// none
	core.pi_installed_probe = proc() -> bool {return false}
	testing.expect_value(t, len(core.new_session_choices(p, "")), 0)
	// a checkout of the project: pi there is a worktree session, Claude a session with that cwd
	h_both()
	wt := h_dir("choices-wt")
	items = core.new_session_choices(p, wt)
	ws, is_ws := items[0].cmd.(core.Worktree_Session)
	testing.expect(t, is_ws && ws.path == wt, "pi in the checkout")
	cs, is_cs := items[1].cmd.(core.New_Claude_Session)
	testing.expect(t, is_cs && cs.cwd == wt, "Claude in the checkout")
}

@(test)
new_session_ui_paths :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	dir := h_dir("nsui")
	pid := core.run_command(core.Add_Project{cwd = dir}, H_UI).created_id
	// none installed: the install hints, nothing starts, no menu
	core.pi_installed_probe = proc() -> bool {return false}
	core.claude_installed_probe = proc() -> bool {return false}
	new_session_ui(pid)
	core.inbox_drain()
	testing.expect_value(t, toast.text, core.NO_HARNESS)
	testing.expect(t, toast.err, "an error toast")
	testing.expect(t, !menu.open, "no picker")
	testing.expect_value(t, len(state.open_sessions), 0)
	// one installed: it starts at once, no picker
	toast_clear()
	core.pi_installed_probe = proc() -> bool {return true}
	new_session_ui(pid)
	core.inbox_drain()
	testing.expect(t, !menu.open, "no picker for one harness")
	testing.expect_value(t, len(state.open_sessions), 1)
	if len(state.open_sessions) == 1 {
		_, is_pi := state.open_sessions[0].tabs[0].kind.(core.Pi_Tab)
		testing.expect(t, is_pi, "a pi session")
	}
	testing.expect_value(t, state.settings.last_harness, core.Harness.Pi)
	// two: the picker, its first choice selected (Enter repeats the last used)
	core.claude_installed_probe = proc() -> bool {return true}
	new_session_ui(pid)
	testing.expect(t, menu.open, "the picker opens")
	ns, is_ns := menu.target.(core.Menu_New_Session)
	testing.expect(t, is_ns && ns.project_id == pid, "for this project")
	items := menu_items()
	testing.expect(t, menu.selected >= 0 && menu.selected < len(items) && items[menu.selected].label == "pi", "pi (the last used) is selected")
	// a number key picks: 2 = Claude Code
	ev := sapp.Event{type = .KEY_DOWN, key_code = ._2}
	testing.expect(t, menu_event(&ev), "the menu takes the key")
	core.inbox_drain()
	testing.expect(t, !menu.open, "closed after the pick")
	testing.expect_value(t, len(state.open_sessions), 2)
	if len(state.open_sessions) == 2 do testing.expect_value(t, state.open_sessions[1].agent, core.Session_Agent.Claude)
	testing.expect_value(t, state.settings.last_harness, core.Harness.Claude)
	// next time Claude Code comes first and is selected
	new_session_ui(pid)
	items = menu_items()
	testing.expect(t, menu.selected >= 0 && items[menu.selected].label == "Claude Code", "Claude Code is selected now")
	esc := sapp.Event{type = .KEY_DOWN, key_code = .ESCAPE}
	menu_event(&esc)
	testing.expect(t, !menu.open, "Esc closes it")
	testing.expect_value(t, len(state.open_sessions), 2)
}

// The new-session actions (⌘N, ⇧⌘N, the menus, the palette) run the picker, not a pi command.
@(test)
new_session_actions_pick :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	dir := h_dir("nsact")
	pid := core.run_command(core.Add_Project{cwd = dir}, H_UI).created_id
	core.run_command(core.Select_Project{pid}, H_UI)
	h_both()
	action_run("new_session")
	testing.expect(t, menu.open, "⇧⌘N: the picker")
	menu_close()
	testing.expect(t, action_by_id("new_claude_session") == nil, "no separate New Claude session action")
	testing.expect(t, action_by_id("new_claude_chat") == nil, "no separate New Claude chat action")
	// the project's menu: one "New session" row, no Claude-only session rows
	menu_open(Menu_Project(pid), {0, 0})
	for it in menu_items() do testing.expect(t, !strings.contains(it.label, "Claude session"), it.label)
	menu_close()
}

// ---- Atlas and jobs need pi (for now) ----

@(test)
atlas_needs_pi :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	core.home_root = h_dir("atlas")
	defer core.home_root = ""
	core.pi_installed_probe = proc() -> bool {return false}
	r := core.run_command(core.Set_Home{open = true}, H_UI)
	testing.expect(t, !r.ok, "refused")
	testing.expect_value(t, r.error, core.ATLAS_NEEDS_PI)
	testing.expect(t, !state.home_open, "the drawer stays shut")
	testing.expect_value(t, len(state.open_sessions), 0)
	testing.expect_value(t, toast.text, core.ATLAS_NEEDS_PI)
	testing.expect(t, !action_ok("toggle_agent"), "not offered in the palette")
	core.pi_installed_probe = proc() -> bool {return true}
	testing.expect(t, action_ok("toggle_agent"), "offered with pi")
}

@(test)
jobs_need_pi_message :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	testing.expect(t, strings.contains(core.JOBS_NEED_PI, "Jobs run pi"), core.JOBS_NEED_PI)
	testing.expect(t, strings.contains(core.JOBS_NEED_PI, "pi_path"), core.JOBS_NEED_PI)
}

// ---- pi's sessions under PI_CODING_AGENT_DIR ----

@(test)
sessions_root_agent_dir :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	old := os.get_env("PI_CODING_AGENT_DIR", context.temp_allocator)
	defer os.set_env("PI_CODING_AGENT_DIR", old)
	os.set_env("PI_CODING_AGENT_DIR", "/custom/agent")
	testing.expect_value(t, core.sessions_root(context.temp_allocator), "/custom/agent/sessions")
	os.set_env("PI_CODING_AGENT_DIR", "")
	testing.expect_value(t, core.sessions_root(context.temp_allocator), fmt.tprintf("%s/.pi/agent/sessions", os.get_env("HOME", context.temp_allocator)))
}

// ---- non-POSIX login shells ----

@(test)
shell_script_argv_posix_or_not :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	for sh in ([]string{"/bin/zsh", "/bin/bash", "/opt/homebrew/bin/bash", "/bin/sh", "/bin/dash", "/bin/ksh", "/usr/local/bin/zsh"}) {
		testing.expect(t, core.shell_is_posix(sh), sh)
		argv := core.shell_script_argv(sh, "exec pi \"$@\"", "pi")
		testing.expect_value(t, strings.join(argv[:], " ", context.temp_allocator), fmt.tprintf("%s -l -c exec pi \"$@\" pi", sh))
	}
	for sh in ([]string{"/opt/homebrew/bin/fish", "/usr/local/bin/nu", "/Users/x/.local/bin/xonsh", "/bin/tcsh", "/bin/csh", "/opt/homebrew/bin/elvish", "/usr/local/bin/pwsh", ""}) {
		if sh != "" do testing.expect(t, !core.shell_is_posix(sh), sh)
	}
	for sh in ([]string{"/opt/homebrew/bin/fish", "/usr/local/bin/nu", "/Users/x/.local/bin/xonsh"}) {
		argv := core.shell_script_argv(sh, "exec pi \"$@\"", "pi")
		testing.expect_value(t, strings.join(argv[:], " ", context.temp_allocator), "/bin/sh -c exec pi \"$@\" pi")
	}
}

// ---- versions from other install layouts (looked at, never run) ----

@(test)
claude_version_layouts :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	base := h_dir("cver")
	ran := fmt.tprintf("%s/ran", base)
	fake := fmt.tprintf("#!/bin/sh\ntouch '%s'\n", ran) // proves it is never run
	pkg :: proc(dir, v: string) {
		os.make_directory_all(dir)
		h_write(fmt.tprintf("%s/package.json", dir), fmt.tprintf(`{{"name":"@anthropic-ai/claude-code","version":"%s"}}`, v))
		h_write(fmt.tprintf("%s/cli.js", dir), "#!/usr/bin/env node\n", exec = true)
	}
	// bun: ~/.bun/bin/claude -> ../install/global/node_modules/@anthropic-ai/claude-code/cli.js
	pkg(fmt.tprintf("%s/home/.bun/install/global/node_modules/@anthropic-ai/claude-code", base), "2.1.310")
	os.make_directory_all(fmt.tprintf("%s/home/.bun/bin", base))
	os.symlink("../install/global/node_modules/@anthropic-ai/claude-code/cli.js", fmt.tprintf("%s/home/.bun/bin/claude", base))
	label, _ := core.claude_version_of(fmt.tprintf("%s/home/.bun/bin/claude", base))
	testing.expect_value(t, label, "2.1.310")
	// pnpm: ~/Library/pnpm/claude is a shell shim naming "$basedir/global/5/node_modules/…/cli.js"
	pn := fmt.tprintf("%s/home/Library/pnpm", base)
	pkg(fmt.tprintf("%s/global/5/node_modules/@anthropic-ai/claude-code", pn), "2.1.311")
	h_write(fmt.tprintf("%s/claude", pn), `#!/bin/sh
basedir=$(dirname "$(echo "$0" | sed -e 's,\\,/,g')")

case `+"`uname`"+` in
    *CYGWIN*) basedir=`+"`cygpath -w \"$basedir\"`"+`;;
esac

if [ -z "$NODE_PATH" ]; then
  export NODE_PATH="$basedir/global/5/.pnpm/node_modules"
fi
if [ -x "$basedir/node" ]; then
  exec "$basedir/node"  "$basedir/global/5/node_modules/@anthropic-ai/claude-code/cli.js" "$@"
else
  exec node  "$basedir/global/5/node_modules/@anthropic-ai/claude-code/cli.js" "$@"
fi
`, exec = true)
	label, _ = core.claude_version_of(fmt.tprintf("%s/claude", pn))
	testing.expect_value(t, label, "2.1.311")
	// nix: /nix/store/<hash>-claude-code-<version>/bin/claude, a makeWrapper script (here under base)
	store := fmt.tprintf("%s/nix/store/0c1a0de0abcdefghijklmnopqrstuvw-claude-code-2.1.312", base)
	os.make_directory_all(fmt.tprintf("%s/bin", store))
	h_write(fmt.tprintf("%s/bin/claude", store), fmt.tprintf("#! /nix/store/xyz-bash-5.2p37/bin/bash -e\nexport DISABLE_AUTOUPDATER=${{DISABLE_AUTOUPDATER-'1'}}\nexec -a \"$0\" \"%s/bin/.claude-wrapped\"  \"$@\" \n", store), exec = true)
	h_write(fmt.tprintf("%s/bin/.claude-wrapped", store), fake, exec = true)
	label, _ = core.claude_version_of(fmt.tprintf("%s/bin/claude", store))
	testing.expect_value(t, label, "2.1.312")
	// mise: ~/.local/share/mise/installs/claude-code/<version>/bin/claude (a native build there)
	mise := fmt.tprintf("%s/home/.local/share/mise/installs/claude-code/2.1.313/bin", base)
	os.make_directory_all(mise)
	h_write(fmt.tprintf("%s/claude", mise), fake, exec = true)
	label, _ = core.claude_version_of(fmt.tprintf("%s/claude", mise))
	testing.expect_value(t, label, "2.1.313")
	// mise's npm backend: installs/npm-anthropic-ai-claude-code/<version>/bin/claude -> ../lib/node_modules/…/cli.js
	mn := fmt.tprintf("%s/home/.local/share/mise/installs/npm-anthropic-ai-claude-code/2.1.314", base)
	pkg(fmt.tprintf("%s/lib/node_modules/@anthropic-ai/claude-code", mn), "2.1.314")
	os.make_directory_all(fmt.tprintf("%s/bin", mn))
	os.symlink("../lib/node_modules/@anthropic-ai/claude-code/cli.js", fmt.tprintf("%s/bin/claude", mn))
	label, _ = core.claude_version_of(fmt.tprintf("%s/bin/claude", mn))
	testing.expect_value(t, label, "2.1.314")
	// a script that names another package: no version from it
	other := fmt.tprintf("%s/other", base)
	h_write(other, "#!/bin/sh\nexec node /opt/x/node_modules/@other/thing/cli.js \"$@\"\n", exec = true)
	label, _ = core.claude_version_of(other)
	testing.expect_value(t, label, "")
	testing.expect(t, !os.exists(ran), "claude was never run")
}

@(test)
pi_version_layouts :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	base := h_dir("pver")
	pkg :: proc(dir, v: string) -> string {
		os.make_directory_all(fmt.tprintf("%s/dist", dir))
		p := fmt.tprintf("%s/package.json", dir)
		h_write(p, fmt.tprintf(`{{"name":"@earendil-works/pi-coding-agent","version":"%s"}}`, v))
		h_write(fmt.tprintf("%s/dist/cli.js", dir), "#!/usr/bin/env node\n", exec = true)
		return p
	}
	// bun: a symlink into its global node_modules
	want := pkg(fmt.tprintf("%s/home/.bun/install/global/node_modules/@earendil-works/pi-coding-agent", base), "1.5.1")
	os.make_directory_all(fmt.tprintf("%s/home/.bun/bin", base))
	os.symlink("../install/global/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", fmt.tprintf("%s/home/.bun/bin/pi", base))
	testing.expect_value(t, core.pkg_version(core.pi_package_of(fmt.tprintf("%s/home/.bun/bin/pi", base))), "1.5.1")
	_ = want
	// pnpm: a shell shim; a package.json in a folder above it (the user's home) is not pi's
	h_write(fmt.tprintf("%s/home/package.json", base), `{"name":"my-dotfiles","version":"9.9.9"}`)
	pn := fmt.tprintf("%s/home/Library/pnpm", base)
	pkg(fmt.tprintf("%s/global/5/node_modules/@earendil-works/pi-coding-agent", pn), "1.5.2")
	h_write(fmt.tprintf("%s/pi", pn), "#!/bin/sh\nbasedir=$(dirname \"$(echo \"$0\" | sed -e 's,\\\\,/,g')\")\nif [ -x \"$basedir/node\" ]; then\n  exec \"$basedir/node\"  \"$basedir/global/5/node_modules/@earendil-works/pi-coding-agent/dist/cli.js\" \"$@\"\nelse\n  exec node  \"$basedir/global/5/node_modules/@earendil-works/pi-coding-agent/dist/cli.js\" \"$@\"\nfi\n", exec = true)
	testing.expect_value(t, core.pkg_version(core.pi_package_of(fmt.tprintf("%s/pi", pn))), "1.5.2")
	// nix: a wrapper in the store's bin/ naming lib/node_modules/…/dist/cli.js
	store := fmt.tprintf("%s/nix/store/0c1a0de0abcdefghijklmnopqrstuvw-pi-coding-agent-1.5.3", base)
	pkg(fmt.tprintf("%s/lib/node_modules/@earendil-works/pi-coding-agent", store), "1.5.3")
	os.make_directory_all(fmt.tprintf("%s/bin", store))
	h_write(fmt.tprintf("%s/bin/pi", store), fmt.tprintf("#! /nix/store/xyz-bash-5.2p37/bin/bash -e\nexec \"/nix/store/xyz-nodejs-22.12.0/bin/node\"  \"%s/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js\" \"$@\"\n", store), exec = true)
	testing.expect_value(t, core.pkg_version(core.pi_package_of(fmt.tprintf("%s/bin/pi", store))), "1.5.3")
	// mise's npm backend: a symlink into its install's lib/node_modules
	mn := fmt.tprintf("%s/home/.local/share/mise/installs/npm-earendil-works-pi-coding-agent/1.5.4", base)
	pkg(fmt.tprintf("%s/lib/node_modules/@earendil-works/pi-coding-agent", mn), "1.5.4")
	os.make_directory_all(fmt.tprintf("%s/bin", mn))
	os.symlink("../lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", fmt.tprintf("%s/bin/pi", mn))
	testing.expect_value(t, core.pkg_version(core.pi_package_of(fmt.tprintf("%s/bin/pi", mn))), "1.5.4")
	// npm's usual layout still works
	np := fmt.tprintf("%s/usr/local/lib/node_modules/@earendil-works/pi-coding-agent", base)
	pkg(np, "1.5.0")
	os.make_directory_all(fmt.tprintf("%s/usr/local/bin", base))
	os.symlink("../lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", fmt.tprintf("%s/usr/local/bin/pi", base))
	testing.expect_value(t, core.pkg_version(core.pi_package_of(fmt.tprintf("%s/usr/local/bin/pi", base))), "1.5.0")
}

// The update command a bar copies follows the layout: bun and pnpm installs update with their own tool.
@(test)
claude_update_command_layouts :: proc(t: ^testing.T) {
	testing.expect_value(t, core.claude_update_command("/Users/me/.bun/install/global/node_modules/@anthropic-ai/claude-code/cli.js"), "bun add -g @anthropic-ai/claude-code@latest")
	testing.expect_value(t, core.claude_update_command("/Users/me/Library/pnpm/claude"), "pnpm add -g @anthropic-ai/claude-code@latest")
	testing.expect_value(t, core.claude_update_command("/Users/me/Library/pnpm/global/5/node_modules/@anthropic-ai/claude-code/cli.js"), "pnpm add -g @anthropic-ai/claude-code@latest")
	testing.expect_value(t, core.claude_update_command("/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"), "npm install -g @anthropic-ai/claude-code@latest")
	testing.expect_value(t, core.claude_update_command("/opt/homebrew/Caskroom/claude-code/2.1.300/claude"), "brew upgrade --cask claude-code")
	testing.expect_value(t, core.claude_update_command("/Users/me/.local/share/claude/versions/2.1.300"), "claude update")
}

// The gear's pi-only row is not shown without pi (one-harness users see nothing extra).
@(test)
gear_reload_pi_row_needs_pi :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	core.pi_installed_probe = proc() -> bool {return false}
	testing.expect(t, !pop_item_shown(.Reload_Pi), "no Reload all pi tabs without pi")
	core.pi_installed_probe = proc() -> bool {return true}
	testing.expect(t, !pop_item_shown(.Reload_Pi), "with pi but no pi tab running (wording_names_installed_harness)")
	testing.expect(t, pop_item_shown(.Rescan), "other rows as ever")
}

// `deckhand DIR` without --claude: pi, or Claude Code when it is the only harness installed.
@(test)
launch_dir_without_pi :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	pid := core.run_command(core.Add_Project{cwd = h_dir("launch")}, H_UI).created_id
	h_both()
	_, is_pi := launch_start(false, pid).(core.New_Chat)
	testing.expect(t, is_pi, "both: pi, as ever")
	core.pi_installed_probe = proc() -> bool {return false}
	_, is_cl := launch_start(false, pid).(core.New_Claude_Session)
	testing.expect(t, is_cl, "Claude Code alone: a Claude session")
	core.claude_installed_probe = proc() -> bool {return false}
	_, is_pi = launch_start(false, pid).(core.New_Chat)
	testing.expect(t, is_pi, "neither: pi (its tab says how to install it)")
}

// ---- review round 1 ----

@(private = "file")
h_wait_lookup :: proc() -> bool {
	for _ in 0 ..< 500 {
		if core.pi_lookup_state() != .Asking do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// A pi only the login shell finds (.zprofile: nvm, fnm, asdf, mise, pnpm) is never "not installed":
// before saying no, Deckhand asks the login shell (`command -v pi`, never pi itself); while it
// asks, pi counts as there. A re-look (the user's New session) stats again but does not ask again.
@(test)
pi_detect_asks_login_shell :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	old_path := strings.clone(os.get_env("PATH", context.temp_allocator))
	defer os.set_env("PATH", old_path)
	os.set_env("DECKHAND_CMD", "")
	defer os.set_env("DECKHAND_CMD", "sleep 30")
	os.set_env("PI_CODING_AGENT_DIR", "")
	dir := h_dir("lookup")
	empty := fmt.tprintf("%s/empty", dir)
	os.make_directory_all(empty)
	os.set_env("PATH", fmt.tprintf("%s:/usr/bin:/bin", empty))
	zbin := fmt.tprintf("%s/zbin", dir)
	os.make_directory_all(zbin)
	h_write(fmt.tprintf("%s/pi", zbin), "#!/bin/sh\nexit 1\n", exec = true) // never run
	asked := fmt.tprintf("%s/asked", dir)
	found := fmt.tprintf("%s/found-sh", dir)
	h_write(found, fmt.tprintf("#!/bin/sh\necho x >> '%s'\necho 'rc noise'\necho '%s/pi'\n", asked, zbin), exec = true)
	os.set_env("SHELL", found)
	core.pi_recheck()
	testing.expect(t, core.pi_installed(), "while the login shell is asked: there")
	testing.expect(t, h_wait_lookup(), "the login shell answered")
	testing.expect(t, core.pi_installed(), "the login shell finds it")
	// a login shell without pi: no, once it answered
	none := fmt.tprintf("%s/none-sh", dir)
	h_write(none, fmt.tprintf("#!/bin/sh\necho x >> '%s'\nexit 1\n", asked), exec = true)
	os.set_env("SHELL", none)
	core.pi_recheck()
	testing.expect(t, core.pi_installed(), "asking again: there meanwhile")
	testing.expect(t, h_wait_lookup())
	testing.expect(t, !core.pi_installed(), "no pi anywhere")
	n_asked := len(strings.split_lines(strings.trim_space(string(os.read_entire_file(asked, context.temp_allocator) or_else nil)), context.temp_allocator))
	// the user's New session looks again (stat only): installed on PATH since, it is found
	testing.expect(t, !core.pi_installed_now(), "still none")
	h_write(fmt.tprintf("%s/pi", empty), "#!/bin/sh\nexit 1\n", exec = true)
	testing.expect(t, core.pi_installed_now(), "installed since: found by a stat")
	n_after := len(strings.split_lines(strings.trim_space(string(os.read_entire_file(asked, context.temp_allocator) or_else nil)), context.temp_allocator))
	testing.expect_value(t, n_after, n_asked) // the login shell was not asked again
}

// Only a login shell that answered cleanly can say "no pi" (exit 0 or command -v's 1, no path). One
// that timed out, could not start or failed otherwise (127, a broken rc file) proves nothing: pi
// counts as there, until a recheck asks again.
@(test)
pi_lookup_unanswered_is_there :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	old_path := strings.clone(os.get_env("PATH", context.temp_allocator))
	defer os.set_env("PATH", old_path)
	os.set_env("DECKHAND_CMD", "")
	defer os.set_env("DECKHAND_CMD", "sleep 30")
	os.set_env("PI_CODING_AGENT_DIR", "")
	old_cap := core.pi_lookup_timeout
	defer core.pi_lookup_timeout = old_cap
	// the cap: short only where the shell hangs, so a loaded machine's slow /bin/sh start is
	// never taken for a timeout (h_wait_lookup gives up after 5 s)
	SHORT_CAP :: 300 * time.Millisecond
	LONG_CAP :: 4 * time.Second
	dir := h_dir("unanswered")
	empty := fmt.tprintf("%s/empty", dir)
	os.make_directory_all(empty)
	os.set_env("PATH", fmt.tprintf("%s:/usr/bin:/bin", empty))
	cases := []struct {
		name, script: string,
	} {
		{"slow", "#!/bin/sh\nexec sleep 5\n"}, // past the cap
		{"broken", "#!/bin/sh\nexit 127\n"}, // no output, a failure that is not command -v's
		{"crashed", "#!/bin/sh\nkill -9 $$\n"}, // killed by a signal
	}
	for c in cases {
		sh := fmt.tprintf("%s/%s-sh", dir, c.name)
		h_write(sh, c.script, exec = true)
		os.set_env("SHELL", sh)
		core.pi_lookup_timeout = c.name == "slow" ? SHORT_CAP : LONG_CAP
		core.pi_recheck()
		_ = core.pi_installed()
		testing.expectf(t, h_wait_lookup(), "%s: the lookup ended", c.name)
		testing.expectf(t, core.pi_installed(), "%s: no clean answer, so pi counts as there", c.name)
	}
	// a shell that cannot start at all
	core.pi_lookup_timeout = LONG_CAP
	os.set_env("SHELL", fmt.tprintf("%s/no-such-shell", dir))
	core.pi_recheck()
	_ = core.pi_installed()
	testing.expect(t, h_wait_lookup(), "spawn error: the lookup ended")
	testing.expect(t, core.pi_installed(), "spawn error: pi counts as there")
	// the clean answers still say no: exit 0 with nothing, command -v's exit 1
	for script in ([]string{"#!/bin/sh\nexit 0\n", "#!/bin/sh\nexit 1\n"}) {
		sh := fmt.tprintf("%s/clean-sh", dir)
		h_write(sh, script, exec = true)
		os.set_env("SHELL", sh)
		core.pi_recheck()
		_ = core.pi_installed()
		testing.expect(t, h_wait_lookup())
		testing.expectf(t, !core.pi_installed(), "a clean no (%q)", script)
	}
}

// PI_CODING_AGENT_DIR as pi reads it: a leading ~ is the home folder; a relative one (pi would take
// it from its cwd, which Deckhand cannot know) falls back to ~/.pi/agent.
@(test)
pi_agent_dir_tilde_and_relative :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	old := strings.clone(os.get_env("PI_CODING_AGENT_DIR", context.temp_allocator))
	defer os.set_env("PI_CODING_AGENT_DIR", old)
	home := os.get_env("HOME", context.temp_allocator)
	os.set_env("PI_CODING_AGENT_DIR", "~/agent-x")
	testing.expect_value(t, core.pi_agent_dir(), fmt.tprintf("%s/agent-x", home))
	testing.expect_value(t, core.sessions_root(context.temp_allocator), fmt.tprintf("%s/agent-x/sessions", home))
	os.set_env("PI_CODING_AGENT_DIR", "~")
	testing.expect_value(t, core.pi_agent_dir(), home)
	os.set_env("PI_CODING_AGENT_DIR", "rel/agent")
	testing.expect_value(t, core.pi_agent_dir(), fmt.tprintf("%s/.pi/agent", home))
	os.set_env("PI_CODING_AGENT_DIR", "/abs/agent")
	testing.expect_value(t, core.pi_agent_dir(), "/abs/agent")
}

// Every New session the user starts looks again (stat only): a harness installed meanwhile is offered.
@(test)
new_session_ui_looks_again :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	dir := h_dir("again")
	pid := core.run_command(core.Add_Project{cwd = dir}, H_UI).created_id
	core.pi_installed_probe = proc() -> bool {return true}
	core.claude_installed_probe = nil
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	home := fmt.tprintf("%s/home", dir)
	os.make_directory_all(fmt.tprintf("%s/.local/bin", home))
	os.set_env("HOME", home)
	old_path := strings.clone(os.get_env("PATH", context.temp_allocator))
	defer os.set_env("PATH", old_path)
	os.set_env("PATH", "/usr/bin:/bin")
	core.claude_recheck()
	testing.expect(t, !core.claude_installed(), "no claude yet (cached)")
	h_write(fmt.tprintf("%s/.local/bin/claude", home), "#!/bin/sh\nexit 1\n", exec = true) // never run
	new_session_ui(pid)
	testing.expect(t, menu.open, "Claude Code installed since: the picker offers both")
	menu_close()
}

// Claude Code from nix or mise: their package manager updates it; no `claude update` to copy.
@(test)
claude_update_nix_mise :: proc(t: ^testing.T) {
	testing.expect_value(t, core.claude_update_command("/nix/store/0c1a0de0abcdefghijklmnopqrstuvw-claude-code-2.1.312/bin/claude"), "")
	testing.expect_value(t, core.claude_update_command("/Users/me/.local/share/mise/installs/claude-code/2.1.313/bin/claude"), "")
	testing.expect(t, strings.contains(core.claude_update_how(""), "package manager"), core.claude_update_how(""))
	testing.expect_value(t, core.claude_update_how("claude update"), "Update it: claude update")
}

// The picker's digits: plain or keypad; with ⌘ (⌘1…) they are not a pick.
@(test)
new_session_digits :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	pid := core.run_command(core.Add_Project{cwd = h_dir("digits")}, H_UI).created_id
	h_both()
	new_session_ui(pid)
	cmd2 := sapp.Event{type = .KEY_DOWN, key_code = ._2, modifiers = sapp.MODIFIER_SUPER}
	menu_event(&cmd2)
	core.inbox_drain()
	testing.expect(t, menu.open, "⌘2 is not a pick")
	testing.expect_value(t, len(state.open_sessions), 0)
	kp := sapp.Event{type = .KEY_DOWN, key_code = .KP_1}
	menu_event(&kp)
	core.inbox_drain()
	testing.expect(t, !menu.open, "keypad 1 picks")
	testing.expect_value(t, len(state.open_sessions), 1)
}

// The picker closes when its project goes (a rescan dropped it).
@(test)
new_session_picker_project_gone :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	pid := core.run_command(core.Add_Project{cwd = h_dir("gone")}, H_UI).created_id
	h_both()
	new_session_ui(pid)
	testing.expect(t, menu.open)
	for p, i in state.projects do if p.id == pid {
		ordered_remove(&state.projects, i)
		break
	}
	ev := sapp.Event{type = .KEY_DOWN, key_code = .ENTER}
	menu_event(&ev)
	testing.expect(t, !menu.open, "closed")
	testing.expect_value(t, len(state.open_sessions), 0)
}

// Without pi, the palette offers nothing of Atlas's.
@(test)
atlas_palette_needs_pi :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	core.pi_installed_probe = proc() -> bool {return false}
	for id in ([]string{"toggle_agent", "ask_agent", "agent_model", "agent_model_pop"}) do testing.expect(t, !action_ok(id), id)
	testing.expect(t, !pop_item_shown(.Agent_Model), "the gear's Atlas model row")
	core.pi_installed_probe = proc() -> bool {return true}
	for id in ([]string{"toggle_agent", "ask_agent", "agent_model"}) do testing.expect(t, action_ok(id), id)
}

@(test)
shell_is_posix_more :: proc(t: ^testing.T) {
	for sh in ([]string{"/usr/local/bin/pwsh-preview", "/Users/x/.local/bin/ysh"}) do testing.expect(t, !core.shell_is_posix(sh), sh)
	testing.expect(t, core.shell_is_posix("/usr/local/bin/osh"), "osh is POSIX")
}


// The wording names the harness that applies, or neither: someone with one harness reads nothing
// about the other (the Settings tab, the palette's settings rows, the gear's reload row, details).
@(test)
wording_names_installed_harness :: proc(t: ^testing.T) {
	context.allocator = h_reset()
	defer h_done()
	home := os.get_env("HOME", context.temp_allocator)
	ad := fmt.tprintf("%s/.pi/agent", home)
	os.make_directory_all(ad)
	_ = os.write_entire_file(fmt.tprintf("%s/settings.json", ad), transmute([]u8)string("{}\n"))
	has_pi_rows :: proc() -> bool {
		for r in core.settings_file_rows() do if r.group == "pi" || r.group == "project" || r.group == "ext" || r.group == "atlas" do return true
		return false
	}
	// pi only
	core.pi_installed_probe = proc() -> bool {return true}
	core.claude_installed_probe = proc() -> bool {return false}
	testing.expect_value(t, settings_title(), "pi settings")
	testing.expect_value(t, settings_tip(), "pi's settings files")
	testing.expect(t, strings.contains(settings_empty_hint(), "pi"), settings_empty_hint())
	testing.expect(t, has_pi_rows(), "pi's files listed")
	// Claude Code only: no pi rows, no pi in the words
	core.pi_installed_probe = proc() -> bool {return false}
	core.claude_installed_probe = proc() -> bool {return true}
	testing.expect_value(t, settings_title(), "Claude Code settings")
	testing.expect_value(t, settings_tip(), "Claude Code's settings files")
	testing.expect(t, !strings.contains(settings_empty_hint(), "pi"), settings_empty_hint())
	testing.expect(t, !has_pi_rows(), "no pi groups without pi")
	// both, or neither: neutral
	h_both()
	testing.expect_value(t, settings_title(), "Settings")
	testing.expect_value(t, settings_tip(), "Settings files")
	// details that named pi for everyone
	if a := action_by_id("chats_readonly"); a != nil && a.detail != nil do testing.expect(t, !strings.contains(a.detail(), "pi"), a.detail())
	testing.expect(t, !strings.contains(RIGHT_EMPTY_HINT, "pi"), RIGHT_EMPTY_HINT)
	// the gear's Reload all pi tabs: only while a pi tab runs, as Restart all Claude tabs
	testing.expect(t, !pop_item_shown(.Reload_Pi), "no pi tab: no reload row")
	testing.expect(t, !pop_item_shown(.Restart_Claude), "no Claude tab: no restart row")
}
