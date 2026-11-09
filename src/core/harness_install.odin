package core

// Running an install or update from the harness checklist (harness_manifest.odin): only after the
// user's click on the checklist's Install or Update, one at a time, in a terminal the checklist
// shows (the setup sheet's Coding agents step: the command, its output live, how it ended; the
// keyboard goes to it while it runs, so ⌃C stops it). Never `sudo`, never silently.
//
//   - What runs: the login shell (as tabs run Deckhand's sh scripts: shell_script_argv) with a
//     short script that prints the exact command, refuses to install a harness that is already
//     there (`command -v`, its managed install: never a second copy), runs the command and says
//     how it ended.
//   - Test mode never runs a real install: DECKHAND_INSTALL_CMD stands in (it gets the item's id
//     and the command as "$@"); without it the run prints a refusal and exits 127.
//   - When it ends, the checklist looks everything up again (harness_checklist_refresh(full)), pi's
//     version too; the existing restart bars take over for tabs on an old version.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

Harness_Run_Status :: enum u8 {
	None,
	Running,
	Done, // exited 0
	Failed, // exited otherwise
}

Harness_Run :: struct {
	term_id: u64, // its terminal (terms; no tab)
	item:    string, // heap: the manifest id
	action:  Harness_Action,
	command: string, // heap: what runs
	status:  Harness_Run_Status,
	exit:    Exit_Info,
	started: time.Tick, // the click (HARNESS_ENTER_GRACE)
	no_sudo: string, // heap: its sudo-refusing folder, removed with the output ("" = none)
}

harness_run: Harness_Run

// Where a harness's own installer puts it (the guard looks there too, besides `command -v`).
// $_pa is pi's agent folder as pi reads PI_CODING_AGENT_DIR ("~" and "~/…" expanded; script below).
@(private = "file")
HARNESS_GUARD_PATHS := [Harness][2]string {
	.Pi     = {`$_pa/bin/pi`, `$HOME/.pi/agent/bin/pi`},
	.Claude = {`$HOME/.local/bin/claude`, `$HOME/.claude/local/claude`},
}

HARNESS_BIN_NAMES := [Harness]string {
	.Pi     = "pi",
	.Claude = "claude",
}

// After the click, Enter is not the terminal's for this long: the habitual Enter (Next) must not
// answer a y/N the command asks at once.
HARNESS_ENTER_GRACE :: time.Second

// sh single quotes around s.
sh_quote :: proc(s: string) -> string {
	q, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return strings.concatenate({"'", q, "'"}, context.temp_allocator)
}

// What a run is aimed at, from the checklist's item (harness_manifest.odin).
Harness_Run_Plan :: struct {
	command:     string,
	target:      string, // the detected binary the command runs ("" = an installer: none)
	target_real: string, // where it linked to when detected
	pm:          string, // the package manager the command runs ("" = none)
	path_dir:    string, // first on PATH ("" = none)
	no_sudo:     string, // the folder whose `sudo` refuses ("" = none)
}

// What every run starts with, in the stand-in's too: `sudo` refuses (a shim first on PATH, which
// says to run the command yourself; SUDO_ASKPASS=/usr/bin/false for sudo -A), then the folder of
// the package manager that owns the detected copy.
@(private = "file")
run_prelude :: proc(b: ^strings.Builder, plan: Harness_Run_Plan) {
	if plan.path_dir != "" do fmt.sbprintf(b, "PATH=%s:\"$PATH\"; ", sh_quote(plan.path_dir))
	if plan.no_sudo != "" do fmt.sbprintf(b, "PATH=%s:\"$PATH\"; ", sh_quote(plan.no_sudo))
	strings.write_string(b, "export PATH; SUDO_ASKPASS=/usr/bin/false; export SUDO_ASKPASS; ")
}

// The script the terminal runs for row r (temp): it says the command; an install of a harness
// stops when one is there already (never a second copy); an update or a pi package's install
// first checks that the copy Deckhand detected is still the one the command runs (its path is
// there and links where it did; the package manager next to it is there) and refuses otherwise,
// naming both; then the command, by absolute paths; then how it ended.
harness_run_script :: proc(r: Harness_Row, action: Harness_Action, plan: Harness_Run_Plan) -> string {
	b := strings.builder_make(context.temp_allocator)
	verb := action == .Update ? "updating" : "installing"
	// the checks run with the login shell's own PATH; the run's (run_prelude) comes just before the command
	fmt.sbprintf(&b, "printf '%%s\\n' %s %s ''; ", sh_quote(fmt.tprintf("Deckhand: %s %s with:", verb, r.name)), sh_quote(fmt.tprintf("  %s", plan.command)))
	refuse :: proc(b: ^strings.Builder, lines: ..string) {
		strings.write_string(b, "{ printf '%s\\n'")
		for l in lines do fmt.sbprintf(b, " %s", l)
		strings.write_string(b, " 'Nothing was run. Open the checklist again (Settings → Coding agents, Refresh).'; exit 1; }")
	}
	if r.kind == .Harness && action == .Install {
		// never a second copy: one found by the login shell or in its installer's folder stops here
		name := HARNESS_BIN_NAMES[r.harness]
		strings.write_string(&b, `_pa=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}; case "$_pa" in "~") _pa=$HOME;; "~/"*) _pa=$HOME/${_pa#"~/"};; esac; `)
		fmt.sbprintf(&b, "_have=$(command -v %s 2>/dev/null); ", name)
		for p in HARNESS_GUARD_PATHS[r.harness] do fmt.sbprintf(&b, "[ -z \"$_have\" ] && [ -f \"%s\" ] && [ -x \"%s\" ] && _have=\"%s\"; ", p, p, p)
		fmt.sbprintf(&b, "if [ -n \"$_have\" ]; then printf '%%s\\n' \"%s is already installed: $_have\" 'Deckhand does not install a second copy.'; exit 0; fi; ", r.name)
	}
	if plan.target != "" {
		t := sh_quote(plan.target)
		fmt.sbprintf(&b, "_t=%s; _d=%s; ", t, sh_quote(plan.target_real))
		strings.write_string(&b, "[ -e \"$_t\" ] || ")
		refuse(&b, sh_quote(fmt.tprintf("Deckhand: %s was detected at", (r.harness == .Pi || r.kind == .Third_Party) ? "pi" : r.name)), "\"  $_t\"", "'but it is not there now.'")
		// where it links now: macOS's own realpath (one on PATH only if that is missing); none, or no
		// answer, refuses (fails closed)
		fmt.sbprintf(&b, "; _rp=%s; [ -x \"$_rp\" ] || _rp=$(command -v realpath 2>/dev/null); [ -n \"$_rp\" ] || ", sh_quote(harness_realpath))
		refuse(&b, "'Deckhand: no realpath to check the copy it detected with.'")
		strings.write_string(&b, "; _r=$(\"$_rp\" \"$_t\" 2>/dev/null); [ -n \"$_r\" ] || ")
		refuse(&b, "\"Deckhand: could not resolve $_t (with $_rp) to check it is the copy it detected.\"")
		strings.write_string(&b, "; [ \"$_r\" = \"$_d\" ] || ")
		refuse(&b, "'Deckhand: the copy it detected is not the one there now:'", "\"  detected: $_t -> $_d\"", "\"  now:      $_t -> $_r\"")
		strings.write_string(&b, "; ")
		name := (r.kind == .Third_Party) ? "pi" : HARNESS_BIN_NAMES[r.harness]
		fmt.sbprintf(&b, "_c=$(command -v %s 2>/dev/null); [ -z \"$_c\" ] || [ \"$_c\" = \"$_t\" ] || printf '%%s\\n' \"Note: your shell's %s is $_c; Deckhand updates the copy it detected, $_t.\" ''; ", name, name)
	}
	if plan.pm != "" {
		fmt.sbprintf(&b, "[ -x %s ] || ", sh_quote(plan.pm))
		refuse(&b, sh_quote(fmt.tprintf("Deckhand: %s, the package manager next to this copy, is not there now.", plan.pm)))
		strings.write_string(&b, "; ")
	}
	run_prelude(&b, plan)
	// a failing download fails the run (bash, zsh and macOS's sh have pipefail)
	strings.write_string(&b, "(set -o pipefail) 2>/dev/null && set -o pipefail; ")
	strings.write_string(&b, plan.command)
	strings.write_string(&b, "\n_s=$?; if [ \"$_s\" = 0 ]; then printf '\\n%s\\n' 'Deckhand: finished. The checklist looks again now.'; else printf '\\n%s\\n' \"Deckhand: it failed (exit $_s).\"; fi; exit $_s")
	return strings.to_string(b)
}

// The argv that runs it: the login shell (or /bin/sh for fish and co.); in test mode the stand-in
// (DECKHAND_INSTALL_CMD, given the item's id and the command, after the same prelude: no sudo), or
// a refusal (refused = true).
harness_run_argv :: proc(r: Harness_Row, action: Harness_Action, plan: Harness_Run_Plan, test: bool, stand_in: string) -> (argv: [dynamic]string, refused: bool) {
	if test {
		argv = make([dynamic]string, context.temp_allocator)
		if stand_in == "" {
			append(&argv, "/bin/sh", "-c", "printf '%s\\n' 'Deckhand test mode: no install stand-in; refusing to run the real install'; exit 127")
			return argv, true
		}
		b := strings.builder_make(context.temp_allocator)
		run_prelude(&b, plan)
		fmt.sbprintf(&b, "%s \"$@\"", stand_in)
		append(&argv, "/bin/sh", "-c", strings.to_string(b), "sh", r.id, plan.command)
		return argv, false
	}
	return shell_script_argv(login_shell(), harness_run_script(r, action, plan), "sh"), false
}

// A folder whose `sudo` refuses and says what to run instead (removed with the run's output).
// "" = it could not be made, or its sudo not made executable: the run does not start.
harness_no_sudo_dir :: proc(command: string) -> string {
	tmp := no_sudo_tmp()
	d := fmt.tprintf("%s/%s%d-%d", tmp, NO_SUDO_PREFIX, os.get_pid(), new_id())
	if posix.mkdir(strings.clone_to_cstring(d, context.temp_allocator), transmute(posix.mode_t)u16(0o700)) != .OK do return ""
	shim := fmt.tprintf("#!/bin/sh\nprintf '%%s\\n' \"Deckhand doesn't run sudo; run this yourself:\" %s >&2\nexit 1\n", sh_quote(fmt.tprintf("  %s", command)))
	p := fmt.tprintf("%s/sudo", d)
	if os.write_entire_file(p, transmute([]u8)shim) != nil {
		os.remove_all(d)
		return ""
	}
	if posix.chmod(strings.clone_to_cstring(p, context.temp_allocator), transmute(posix.mode_t)u16(0o755)) != .OK {
		os.remove_all(d)
		return ""
	}
	return d
}

// The user's Install or Update on a checklist item (its cached state says which, and the command).
// "" = started; else why not.
harness_run_start :: proc(id: string) -> string {
	if harness_run.status == .Running do return "Another install is running: wait for it (⌃C in its terminal stops it)"
	it := harness_item(id)
	r, ok := harness_row(id)
	if it == nil || !ok do return "no such item"
	if it.action == .None do return fmt.tprintf("%s needs nothing", r.name)
	if !it.runnable || it.command == "" do return fmt.tprintf("Deckhand does not run this one: %s", it.command != "" ? it.command : "update it with its package manager")
	harness_run_dismiss()
	plan := Harness_Run_Plan{command = it.command, target = it.target, target_real = it.target_real, path_dir = it.path_dir, pm = it.pm}
	plan.no_sudo = harness_no_sudo_dir(it.command)
	if plan.no_sudo == "" do return fmt.tprintf("Deckhand could not make the folder that keeps sudo out of the run (in %s): nothing was run", no_sudo_tmp())
	when ODIN_TEST {
		if !test_mode() do return "unit tests never run a real install" // a guard on the tests themselves
	}
	test := test_mode()
	stand_in := hook_env(.Install_Cmd)
	argv, refused := harness_run_argv(r, it.action, plan, test, stand_in)
	if refused do test_mode_refused("install command")
	id_ := new_id()
	t := new_term(id_)
	home := os.get_env("HOME", context.temp_allocator)
	if !term_start(t, argv[:], home != "" ? home : "/") {
		drop_term(id_)
		if plan.no_sudo != "" do os.remove_all(plan.no_sudo)
		return "could not start the terminal"
	}
	harness_run = {term_id = id_, item = strings.clone(id), action = it.action, command = strings.clone(it.command), status = .Running, started = time.tick_now(), no_sudo = strings.clone(plan.no_sudo)}
	window_state_changed()
	return ""
}

// pump_all: the run's process exited.
harness_run_exited :: proc(exit: Exit_Info) {
	if harness_run.status != .Running do return
	harness_run.exit = exit
	harness_run.status = exit.known && exit.code == 0 && exit.signal == 0 ? .Done : .Failed
	pi_version_probe_again() // pi may have a new version (reload.odin)
	window_setup_sheet(.Clear_Error) // "an install is running" no longer holds
	harness_checklist_refresh(full = true)
}

// The output goes (Close): the terminal is dropped, a running one stopped first.
harness_run_dismiss :: proc() {
	if harness_run.term_id != 0 do drop_term(harness_run.term_id)
	if harness_run.no_sudo != "" do os.remove_all(harness_run.no_sudo)
	delete(harness_run.no_sudo)
	delete(harness_run.item)
	delete(harness_run.command)
	harness_run = {}
	window_state_changed()
}

harness_run_term :: proc() -> ^Term {
	return harness_run.term_id != 0 ? term_of(harness_run.term_id) : nil
}

// The realpath the target check runs (tests point it elsewhere).
harness_realpath := "/bin/realpath"

@(private = "file")
NO_SUDO_PREFIX :: "deckhand-no-sudo-"

@(private = "file")
no_sudo_tmp :: proc() -> string {
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	return tmp != "" ? tmp : "/tmp"
}

// Leftover no-sudo folders (a crash, a quit mid-run): at quit this process's; at start those of
// processes no longer running. Only folders this user owns, by their name's pid.
// $TMPDIR can hold hundreds of thousands of entries (other programs' leftovers): it is read by
// name only (no_sudo_names), and only the folders named like ours are stat'ed. os's directory
// listing stats every entry: 200k entries took ~18 s at every start and quit, on the main thread.
harness_no_sudo_sweep :: proc(at_quit: bool) {
	tmp := no_sudo_tmp()
	me := os.get_pid()
	uid := posix.getuid()
	for name in no_sudo_names(tmp) {
		rest := name[len(NO_SUDO_PREFIX):]
		pid_s, _, _ := strings.partition(rest, "-")
		pid, ok := strconv.parse_int(pid_s)
		if !ok do continue
		p := fmt.tprintf("%s/%s", tmp, name)
		st: posix.stat_t
		if posix.lstat(strings.clone_to_cstring(p, context.temp_allocator), &st) != .OK || st.st_uid != uid || !posix.S_ISDIR(st.st_mode) do continue
		if at_quit {
			if pid == me do os.remove_all(p)
		} else if pid != me && posix.kill(posix.pid_t(pid), nil) != .OK && posix.errno() == .ESRCH {
			os.remove_all(p)
		}
	}
}

// The names in dir that start with NO_SUDO_PREFIX (temp-allocated), read with readdir alone:
// nothing else in the folder is stat'ed.
no_sudo_names :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	d := posix.opendir(strings.clone_to_cstring(dir, context.temp_allocator))
	if d == nil do return out[:]
	defer posix.closedir(d)
	for {
		e := posix.readdir(d)
		if e == nil do break
		name := string(cstring(raw_data(e.d_name[:])))
		if strings.has_prefix(name, NO_SUDO_PREFIX) do append(&out, strings.clone(name, context.temp_allocator))
	}
	return out[:]
}

// Whether an install holds the setup sheet (nothing moves the keyboard off it).
harness_run_holds_sheet :: proc() -> bool {
	return harness_run.status == .Running && state.focus_widget == "setup"
}
