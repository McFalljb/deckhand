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
import clay "../build/clay-odin"

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
	if tab == nil || tab.status != .Exited do return false
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
		toast_show(fmt.tprintf("Restart %s: could not start pi", session_where(s)), err = true)
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
		toast_show(p.claude ? "Claude is not ready for a message: type /model in its prompt to pick a model" : "pi has not said it is ready: press Ctrl+L in its terminal to pick a model", err = true)
	}
}

// ---- the bar over a dead pi tab (ui.odin's centre) ----

Dead_Part :: enum u8 {
	Restart,
	Restart_Model,
}

Hit_Dead_Tab :: struct {
	part: Dead_Part,
}

@(private = "file")
DEAD_IDS := [Dead_Part]string {
	.Restart       = "dead_restart",
	.Restart_Model = "dead_restart_model",
}

@(private = "file")
DEAD_LABELS := [Dead_Part]string {
	.Restart       = "Restart",
	.Restart_Model = "Restart with model…",
}
@(private = "file")
DEAD_MODEL_SHORT :: "Model…" // the narrow bar's

// The tab pane p shows when it is a dead pi or Claude tab (Home is the
// drawer's, with its own "stopped").
@(private = "file")
dead_shown :: proc(p: ^Pane) -> ^Tab {
	s := cur()
	if s == nil || s.home do return nil
	tab := pane_shown(p)
	if !tab_is_dead(tab) do return nil
	return tab
}

dead_tab_bar_layout :: proc(p: ^Pane) {
	th := theme()
	// a restart waiting for the old process: said, no buttons
	if s := cur(); s != nil && !s.home {
		if tab := pane_shown(p); tab != nil && tab.status == .Exited && restart_waiting(tab.id) {
			if clay.UI(cid("dead_bar"))({
				layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(EDITOR_BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
				backgroundColor = cc(th.bg_elevated),
				border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
			}) {
				dot(th.text_muted)
				_, is_claude := tab.kind.(Claude_Tab)
				clay.TextDynamic(clip(is_claude ? "Restarting: waiting for the old Claude to exit…" : "Restarting: waiting for the old pi to exit…", max(pane_width() - px(2 * TERM_PAD + DOT + SP_2), px(40))), txt(th.text))
			}
			return
		}
	}
	tab := dead_shown(p)
	if tab == nil do return
	failed := exit_failed(tab.exit)
	model := dead_tab_offers_model(tab) // "Restart with model…"
	msg := dead_tab_tip(tab)
	if failed do msg = strings.concatenate({msg, " — its last output is below"}, context.temp_allocator)
	// a narrow centre: the short label, so both buttons keep their text
	model_label := DEAD_LABELS[.Restart_Model]
	buttons_w :: proc(model_label: string, model: bool) -> f32 {
		w := text_w(DEAD_LABELS[.Restart], WEIGHT_BOLD) + px(2 * SP_3 + SP_2)
		if model do w += text_w(model_label) + px(2 * SP_3 + SP_2)
		return w
	}
	fixed := px(2 * TERM_PAD + DOT + 2 * SP_2)
	if model && pane_width() - fixed - buttons_w(model_label, model) < px(80) do model_label = DEAD_MODEL_SHORT
	room := max(pane_width() - fixed - buttons_w(model_label, model), px(40))
	if clay.UI(cid("dead_bar"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(EDITOR_BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}) {
		dot(failed ? th.error : th.text_muted)
		clay.TextDynamic(clip(msg, room), txt(th.text))
		spacer()
		if model do button(cid(DEAD_IDS[.Restart_Model]), model_label, false, ui_hover == Hit(Hit_Dead_Tab{.Restart_Model}))
		button(cid(DEAD_IDS[.Restart]), DEAD_LABELS[.Restart], true, ui_hover == Hit(Hit_Dead_Tab{.Restart}))
	}
}

dead_tab_hit :: proc() -> Hit {
	if dead_shown(hit_pane()) == nil do return nil // the bar of the pane under the pointer (ui_panes.odin)
	for id, part in DEAD_IDS do if clay.PointerOver(cid(id)) do return Hit_Dead_Tab{part}
	return nil
}

dead_tab_tip_for :: proc(h: Hit_Dead_Tab) -> (label, keys: string) {
	if tab := dead_shown(hit_pane()); tab != nil {
		if _, is := tab.kind.(Claude_Tab); is {
			if h.part == .Restart_Model do return "Start Claude Code again, resuming its conversation, then pick another model (/model)", ""
			return "Start Claude Code again in this tab, resuming its conversation", ""
		}
	}
	switch h.part {
	case .Restart:       return "Start pi again in this tab, on the same session", ""
	case .Restart_Model: return "Start pi again on the same session, then pick another model in pi's selector", ""
	}
	return "", ""
}

dead_tab_click :: proc(p: ^Pane, h: Hit_Dead_Tab) {
	tab := dead_shown(p)
	if tab == nil do return
	if _, is := tab.kind.(Claude_Tab); is do ui_do(Claude_Restart{tab_id = tab.id, pick_model = h.part == .Restart_Model})
	else do ui_do(Pi_Restart{tab_id = tab.id, pick_model = h.part == .Restart_Model})
	if state.focus_widget != "" do ui_do(Set_Focus{""}) // the keyboard goes to the new pi
	app.redraw = true
}

// A dead pi or Claude tab's tooltip (its tab, its Open row): how it ended. "" = none.
dead_tab_hover_tip :: proc(tab: ^Tab) -> string {
	if !tab_is_dead(tab) do return ""
	return fmt.tprintf("%s — open it again to restart", dead_tab_tip(tab))
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
		toast_show(CLAUDE_MISSING_HINT, err = true)
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
		toast_show(fmt.tprintf("Restart %s: could not start Claude Code", session_where(s)), err = true)
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
