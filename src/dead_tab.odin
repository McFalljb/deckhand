package main

// A pi or Claude tab whose process exited (a "dead tab"). A Claude tab's bar has Restart:
// claude again in the same tab with --resume <its Claude session id> (claude_tab_restart), plus
// "Restart with model…" when it failed: then pi-desk pastes its own /model (Claude Code's model
// picker) once the new Claude is idle with bracketed paste on and nothing typed (as Send now
// pastes), so the user picks from the models Claude Code offers them.
// A pi tab whose process exited (a "dead tab"). How it ended (exit code or
// signal, reaped in term.odin) is kept on the tab (Tab.exit), written into
// its terminal, the state and the command log (tab_exited), and shown in a
// bar over the tab with Restart, plus "Restart with model…" when it failed.
// Opening its session again (its row, the palette, the bell, open_session)
// starts pi again in the same tab on the same session file, as a restored
// tab starts. "Restart with model…" then opens pi's own model selector
// (PI_MODEL_SELECT_KEY) once the new pi reports, so the user picks from the
// models pi offers and goes on in the same session.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// "code 3", "signal 1 (SIGHUP)", or "" when unknown.
exit_text :: proc(e: Exit_Info) -> string {
	if !e.known do return ""
	if e.signal == 0 do return fmt.tprintf("code %d", e.code)
	if e.signal > 0 && e.signal < len(SIGNAL_NAMES) && SIGNAL_NAMES[e.signal] != "" do return fmt.tprintf("signal %d (%s)", e.signal, SIGNAL_NAMES[e.signal])
	return fmt.tprintf("signal %d", e.signal)
}

// macOS's numbers (the common ones are the same on Linux).
@(private = "file")
SIGNAL_NAMES := [?]string{1 = "SIGHUP", 2 = "SIGINT", 3 = "SIGQUIT", 4 = "SIGILL", 5 = "SIGTRAP", 6 = "SIGABRT", 8 = "SIGFPE", 9 = "SIGKILL", 10 = "SIGBUS", 11 = "SIGSEGV", 13 = "SIGPIPE", 14 = "SIGALRM", 15 = "SIGTERM", 24 = "SIGXCPU", 25 = "SIGXFSZ", 30 = "SIGUSR1", 31 = "SIGUSR2"}

// It did not end cleanly (or nobody knows).
exit_failed :: proc(e: Exit_Info) -> bool {
	return !e.known || e.code != 0 || e.signal != 0
}

// The tab's "not found" (PI_TAB_CMD): pi is neither on the PATH nor in its managed install.
exit_not_found :: proc(e: Exit_Info) -> bool {
	return e.known && e.signal == 0 && e.code == 127
}

// "pi exited (code 1)": the bar's text and the tab's and row's tooltip.
dead_tab_tip :: proc(tab: ^Tab) -> string {
	if _, is_claude := tab.kind.(Claude_Tab); is_claude {
		if exit_not_found(tab.exit) do return "Claude Code isn't installed (or not on your login PATH)"
		if how := exit_text(tab.exit); how != "" do return fmt.tprintf("Claude exited (%s)", how)
		return "Claude exited"
	}
	if exit_not_found(tab.exit) do return "pi was not found on your login shell's PATH, in $PI_CODING_AGENT_DIR/bin or in ~/.pi/agent/bin (code 127)"
	if how := exit_text(tab.exit); how != "" do return fmt.tprintf("pi exited (%s)", how)
	return "pi exited"
}

// "Restart with model…" is offered: pi or Claude failed, and another model may help
// (not when the program itself was not found).
dead_tab_offers_model :: proc(tab: ^Tab) -> bool {
	#partial switch _ in tab.kind {
	case Pi_Tab, Claude_Tab:
	case: return false
	}
	return exit_failed(tab.exit) && !exit_not_found(tab.exit)
}

// What pi-desk pastes into a restarted Claude for "Restart with model…": Claude Code's model
// picker (its built-in slash command; a key binding could be rebound).
CLAUDE_MODEL_COMMAND :: "/model"
// How long a restarted Claude has to be ready for it.
CLAUDE_PICKER_WAIT :: 30 * time.Second

// A pi or Claude tab that exited by itself (not one a restart is stopping,
// or one whose restart waits for the old process).
tab_is_dead :: proc(tab: ^Tab) -> bool {
	if tab == nil || tab.status != .Exited || tab_held_away(tab) != 0 do return false // still runs in the holder: no Restart
	switch _ in tab.kind {
	case Pi_Tab, Claude_Tab:
	case Shell_Tab, Editor_Tab, Changes_Tab, Markdown_Tab, Browser_Tab, App_Tab:
		return false
	}
	return !reload_step_is(tab, true) && !restart_waiting(tab.id)
}

// Opening a session again: its pi starts again if it exited (a failure is
// said by pi_tab_restart); so does the Claude tab it shows, unless claude is
// still not found (its bar says so: nothing is started, nothing more said).
// user: the user opened it (a Claude tab gets its saved flags, CLAUDE.md §3).
restart_if_dead :: proc(s: ^Open_Session, user := false) {
	if s.missing do return
	if tab := session_pi_tab(s); tab_is_dead(tab) do pi_tab_restart(s, tab, false)
	again :: proc(s: ^Open_Session, tab: ^Tab, user: bool) {
		if tab == nil do return
		if _, is := tab.kind.(Claude_Tab); !is || !tab_is_dead(tab) do return
		if exit_not_found(tab.exit) && !claude_installed_now() do return
		claude_tab_restart(s, tab, user)
	}
	// a Claude-only session's main tab, as a pi session's pi tab (claude.odin)
	if s.agent == .Claude && len(s.tabs) > 0 do again(s, &s.tabs[0], user)
	_, tab, _ := find_tab(s.active_tab)
	again(s, tab, user)
}

// pi starts again in the tab, on its session, as a restored tab does (its
// old terminal, tokens and confirmations go). pick_model: pi's model
// selector opens once the new pi reports (dead_tab_tick). An old process
// that closed its terminal without exiting (hung up on, still dying) is
// waited for first, so two pi never write one session file. If pi cannot
// start, the tab stays as it was (its output, how it ended) and a toast
// says so.
pi_tab_restart :: proc(s: ^Open_Session, tab: ^Tab, pick_model: bool) -> Result {
	if t := term_of(tab.id); t != nil && t.hung_pid > 0 && pty_dying(t.hung_pid) {
		append(&restart_waits, Restart_Wait{tab = tab.id, pid = t.hung_pid, since = time.tick_now(), pick_model = pick_model})
		return {ok = true, created_id = tab.id}
	}
	forget_confirmations_for(tab.id)
	socket_forget_tab(tab.id)
	tab_clear_panels(tab)
	if agent_picker.tab == tab.id do agent_picker = {}
	picker_drop(tab.id)
	tab.agent, tab.waiting, tab.question = .Unknown, false, false
	for b in tab.blockers do delete(b)
	clear(&tab.blockers)
	prog_summary_free(&tab.prog) // the old pi's OSC 7501 status (agent_status.odin)
	// a new chat whose bridge never said where its file is: pi may have
	// written it by now (resumed then, rather than a second file)
	if s.session_file == "" && !s.home {
		if p := find_project(s.project_id); p != nil {
			if f := find_session_file(p^, s.pi_session_id, s.session_dir); f != "" do s.session_file = strings.clone(f)
		}
	}
	// the old terminal is kept aside until the new pi runs
	old := term_of(tab.id)
	if old != nil do delete_key(&terms, tab.id)
	exit := tab.exit
	tab.exit = {}
	if !start_pi_tab_again(s, tab) {
		drop_term(tab.id)
		if old != nil do terms[tab.id] = old
		tab.status, tab.exit = .Exited, exit
		window_toast(fmt.tprintf("Restart %s: could not start pi", session_where(s)), err = true)
		return fail("could not start pi")
	}
	if old != nil {
		term_free(old)
		free(old)
	}
	if pick_model do append(&restart_pickers, Restart_Pick{tab = tab.id, deadline = time.tick_add(time.tick_now(), PICKER_WAIT)})
	return {ok = true, created_id = tab.id}
}

// "Restart with model…": tabs whose new pi gets the model selector once it
// reports (a Claude tab: /model once it is ready).
Restart_Pick :: struct {
	tab:      u64,
	deadline: time.Tick,
	claude:   bool,
}
restart_pickers: [dynamic]Restart_Pick

// Restarts waiting for the old process (hung up on) to be gone; it gets
// SIGKILL after RESTART_EXIT_WAIT, as a hot-reload restart's does.
Restart_Wait :: struct {
	tab:        u64,
	pid:        i32,
	since:      time.Tick,
	pick_model: bool,
	claude:     bool, // a Claude tab (claude_tab_restart)
	flags:      bool, // its saved flags (the user's restart)
}
restart_waits: [dynamic]Restart_Wait

restart_picking :: proc(tab: u64) -> bool {
	for p in restart_pickers do if p.tab == tab do return true
	return false
}

restart_waiting :: proc(tab: u64) -> bool {
	for w in restart_waits do if w.tab == tab do return true
	return false
}

@(private = "file")
picker_drop :: proc(tab: u64) {
	for i := len(restart_pickers) - 1; i >= 0; i -= 1 do if restart_pickers[i].tab == tab do ordered_remove(&restart_pickers, i)
}

// Tests: nothing pending.
dead_tab_reset :: proc() {
	clear(&restart_pickers)
	clear(&restart_waits)
}

// The frame's tick. A waiting restart starts once the old process is gone
// (killed after RESTART_EXIT_WAIT). The selector key goes to a restarted
// pi once its bridge reports (and no dialog of its would take the key);
// without a report before the deadline the user is told how to open it.
dead_tab_tick :: proc(now := time.Tick{}) {
	if len(restart_pickers) == 0 && len(restart_waits) == 0 do return
	n := now == {} ? time.tick_now() : now
	for i := len(restart_waits) - 1; i >= 0; i -= 1 {
		w := restart_waits[i]
		s, tab, _ := find_tab(w.tab)
		if tab == nil || tab.status != .Exited {
			ordered_remove(&restart_waits, i) // closed, or started some other way
			continue
		}
		if pty_dying(w.pid) {
			if time.tick_diff(w.since, n) > RESTART_EXIT_WAIT do posix.kill(posix.pid_t(w.pid), .SIGKILL)
			continue
		}
		ordered_remove(&restart_waits, i)
		if t := term_of(tab.id); t != nil do t.hung_pid = 0
		if w.claude do claude_tab_restart(s, tab, w.flags, w.pick_model)
		else do pi_tab_restart(s, tab, w.pick_model)
	}
	for i := len(restart_pickers) - 1; i >= 0; i -= 1 {
		p := restart_pickers[i]
		_, tab, _ := find_tab(p.tab)
		t := term_of(p.tab)
		if tab == nil || t == nil || !t.running || tab.status != .Running {
			ordered_remove(&restart_pickers, i) // gone, or exited again (its bar says so)
			continue
		}
		if p.claude {
			// held-prompt rules (claude_ready): idle per hooks and OSC 7501, bracketed paste, nothing typed
			if claude_paste_message(tab, CLAUDE_MODEL_COMMAND, slash = true) == "" {
				ordered_remove(&restart_pickers, i)
				term_scroll_to_bottom(t)
				continue
			}
		} else if tab.agent != .Unknown && !tab.waiting {
			ordered_remove(&restart_pickers, i)
			pty_write(&t.pty, transmute([]u8)string(PI_MODEL_SELECT_KEY))
			term_scroll_to_bottom(t)
			continue
		}
		if time.tick_diff(n, p.deadline) > 0 do continue
		ordered_remove(&restart_pickers, i)
		window_toast(p.claude ? "Claude is not ready for a message: type /model in its prompt to pick a model" : "pi has not said it is ready: press Ctrl+L in its terminal to pick a model", err = true)
	}
}


// ---- a dead Claude tab ----

// Restart refused because claude is still not found (exit 127 and claude_installed says no).
CLAUDE_MISSING_HINT :: "Claude Code is still not installed (or not on your login PATH): install it, or add its folder to PATH in your shell's login profile (~/.zprofile for zsh), then press Restart"

// Claude Code starts again in a dead Claude tab, as a restored tab starts (--resume <its Claude
// session id> when it has one; claude_start mints a new token). flags: the tab's saved flags
// (only the user's restart; anyone else's starts with --plugin-dir and --resume alone, §3).
// An old process that closed its terminal without exiting is waited for first (two claude never
// share a conversation). Exit 127 and claude still not found: nothing starts, the hint says why
// (never a restart loop). If claude cannot start, the tab stays as it was and a toast says so.
claude_tab_restart :: proc(s: ^Open_Session, tab: ^Tab, flags: bool, pick_model := false) -> Result {
	ct, is := &tab.kind.(Claude_Tab)
	if !is do return fail("no such Claude tab")
	if s.missing do return fail("this session is gone")
	if t := term_of(tab.id); t != nil && t.hung_pid > 0 && pty_dying(t.hung_pid) {
		append(&restart_waits, Restart_Wait{tab = tab.id, pid = t.hung_pid, since = time.tick_now(), claude = true, flags = flags, pick_model = pick_model})
		return {ok = true, created_id = tab.id}
	}
	if exit_not_found(tab.exit) && !claude_installed_now() {
		window_toast(CLAUDE_MISSING_HINT, err = true)
		return fail(CLAUDE_MISSING_HINT)
	}
	forget_confirmations_for(tab.id)
	socket_forget_tab(tab.id)
	tab_clear_panels(tab)
	claude_work_reset(tab.id)
	prog_summary_free(&tab.prog)
	old := term_of(tab.id)
	if old != nil do delete_key(&terms, tab.id)
	exit := tab.exit
	tab.exit = {}
	cwd := tab.cwd != "" && os.is_dir(tab.cwd) ? tab.cwd : s.cwd
	if !claude_start(s, new_term(tab.id), tab.id, ct, cwd, flags, defaults = flags) { // the user's restart: the default flags as set now
		drop_term(tab.id)
		if old != nil do terms[tab.id] = old
		tab.status, tab.exit = .Exited, exit
		window_toast(fmt.tprintf("Restart %s: could not start Claude Code", session_where(s)), err = true)
		return fail("could not start Claude Code")
	}
	if old != nil {
		term_free(old)
		free(old)
	}
	tab.status = .Running
	tab.reload.started = false // a new process: its Claude Code version is recorded anew (claude_reload.odin)
	picker_drop(tab.id)
	if pick_model do append(&restart_pickers, Restart_Pick{tab = tab.id, deadline = time.tick_add(time.tick_now(), CLAUDE_PICKER_WAIT), claude = true})
	return {ok = true, created_id = tab.id}
}
