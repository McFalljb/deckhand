package main

// Claude Code tabs (docs/CLAUDE.md): `claude` in a terminal tab of an open session, started
// with pi-desk's own plugin (`--plugin-dir`, integrations/claude-code/, copied into the app
// bundle) and nothing installed in the user's Claude Code config.
//
//   - The plugin's hooks and its `pi-desk` command (bin/pi-desk -> the bundled pi-desk-cli, so
//     plugin and app versions always match) talk to pi-desk over the control socket with a
//     per-tab token in PI_DESK_CLAUDE_TOKEN. The token is caller `panel` with `claude` set: it
//     may do exactly what a pi tab's bridge may (its own session's browser and app tabs,
//     queries) minus the pi bridge's reports (pi.status, panel.set, pi.attached), plus the
//     claude.* reports below for its own tab. It is multi-use (the CLI is a new process per
//     call), never logged, revoked when the tab's process exits or the tab closes, and a hello
//     with it is refused unless the connecting process descends from the tab's own process
//     (socket.odin, socket_claude_peer_ok).
//   - claude.session (SessionStart hook): Claude's session id, kept with the tab and in
//     `claude_history` (saved), so a relaunch restores the tab with `--resume <id>` and the
//     project's "…" menu offers "Resume Claude: <title>".
//   - claude.turn (UserPromptSubmit, Stop, Notification hooks): submitted, idle or waiting. Text
//     pi-desk sends into the tab (claude_prompt: Atlas, scripts) is held until the turn is idle
//     and the user has typed nothing since their last submitted prompt (claude_tick). The
//     Claude's own OSC 7501 status (agent_status.odin) must agree: either one working or
//     waiting holds the text (claude_ready).
//   - claude.comments / claude.attached (UserPromptSubmit hook): the session's pending comments
//     go with the user's next message to Claude as the hook's additionalContext, then are
//     cleared, as pi.attach / pi.attached do for pi (comments.odin, comments_claude_take).

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

Claude_Turn :: enum u8 {
	Unknown, // no hook reported yet (starting, or the plugin's hooks do not run)
	Idle, // SessionStart, Stop: waiting for the user's next prompt
	Working, // a prompt was submitted (UserPromptSubmit), or pi-desk just sent one
	Waiting, // a permission or question dialog (Notification hook)
}
CLAUDE_TURN_NAMES := [Claude_Turn]string {
	.Unknown = "unknown",
	.Idle    = "idle",
	.Working = "working",
	.Waiting = "waiting",
}

// A text held for a Claude tab until it can go without landing in a half-typed prompt.
Claude_Held :: struct {
	id:   u64, // claude_held_id (claude_wait.odin): claude_wait_idle's prompt_id
	text: string,
	who:  string, // who sent it: "Atlas", "a script", "you"
}

Claude_Tab :: struct {
	session_id: string, // Claude Code's session id (claude.session); "" until its SessionStart hook ran
	args:       []string, // the user's extra flags; kept, and passed again on resume and restore
	readonly:   bool, // started with pi-desk's read-only profile (§1a): kept, saved, never dropped
	guard_stopped: bool, // pi-desk stopped it: its profile never confirmed it loaded (claude_readonly_tick; not saved)
	turn:       Claude_Turn,
	held:       [dynamic]Claude_Held, // claude_prompt texts waiting for an idle, empty prompt; at most CLAUDE_HELD_MAX
	model:      string, // Claude's model (SessionStart's model, PostModelSwitch; claude_rows.odin); "" = not reported
	ended:      Claude_Ended, // how its last turn ended (Stop, StopFailure): a question or error dot (claude_rows.odin)
	account:    string, // its Claude Code account's config folder (claude_accounts.odin; "" = the default); saved
	resume_path: string, // a transcript found on disk: --resume takes its absolute path (claude_disk.odin); "" = by id
}

// A Claude Code session pi-desk ran, for Resume (the project's "…" menu) and restore.
Claude_Record :: struct {
	id:      string, // Claude's session id
	cwd:     string, // where it ran
	project: string, // its project's folder
	title:   string, // the first prompt's first line (claude.turn), "" until one
	used:    i64, // unix seconds, last reported or closed
	args:    []string, // the tab's extra flags
	named:   bool, // title is the user's rename (Claude_Rename): pushed to Claude Code as its session title
	transcript: string, // Claude Code's transcript file (SessionStart's transcript_path), only under its config dir's projects/ (claude_rows.odin)
	model:   string, // the model it last reported
	readonly: bool, // it ran read-only: every resume of it is read-only too (§1a)
	account: string, // its account's config folder (claude_accounts.odin); "" = the default (older entries)
}

CLAUDE_HISTORY_MAX :: 100
CLAUDE_HELD_MAX :: 8
CLAUDE_PROMPT_MAX :: 64 * 1024
CLAUDE_TITLE_MAX :: 80
CLAUDE_ARGS_MAX :: 16
CLAUDE_COMMENTS_MAX :: 9500 // the hook's additionalContext is capped at 10,000 characters
CLAUDE_ENTER_DELAY :: 80 * time.Millisecond // a held text's Enter, after its paste

// ---- commands (rows in command_table.odin) ----

New_Claude_Tab :: struct {
	session:    u64, // the open session (0: project_id's, see claude_host)
	project_id: u64,
	cwd:        string, // a folder inside the project ("" = the session's)
	resume:     string, // a Claude session id to resume ("" = a new conversation)
	args:       []string, // extra flags; the user's (and scripts') only
	account:    string, // a configured account's label or folder ("" = the resumed entry's, else the last used)
}
// A Claude-only session in a project (its main tab a Claude tab, no pi tab).
New_Claude_Session :: struct {
	project_id: u64,
	cwd:        string,
	args:       []string,
	account:    string, // a configured account's label or folder ("" = the project's last used, else the last used)
}
// A pi-desk title for a Claude session of the history (the user's; "" = none).
Claude_Rename :: struct {
	claude_session_id: string,
	title:             string,
}
Claude_Resume :: struct {
	claude_session_id: string, // a claude_history entry
}
// From the tab's own plugin (or a test script): its session id, after SessionStart.
Claude_Session_Report :: struct {
	tab_id:          u64,
	session_id:      string,
	cwd:             string,
	source:          string,
	transcript_path: string, // kept only under Claude's config dir's projects/ (claude_transcript_ok)
	model:           string,
}
Claude_Turn_Report :: struct {
	tab_id:   u64,
	state:    string, // submitted | idle | waiting | error (StopFailure)
	title:    string, // with submitted: the prompt's first line (history title); never logged
	question: bool, // with idle: Claude's last answer ends with a question (Stop's last_assistant_message; never sent)
	idle_prompt: bool, // with idle: Notification idle_prompt (not a Stop): the last turn's dot stays
}
Claude_Comments :: struct {
	tab_id: u64,
	max:    int, // characters of text at most (default and cap CLAUDE_COMMENTS_MAX)
}
Claude_Attached :: struct {
	tab_id:        u64,
	attachment_id: u64,
}
// Text for a Claude tab as a user message: held until it can go (claude_tick).
Claude_Prompt :: struct {
	tab_id: u64,
	text:   string,
}
// The held strip's Send now / Drop (the user's).
Claude_Held_Op :: struct {
	tab_id: u64,
	op:     string, // send | drop
}
// claude_tick: a held text can go now (internal).
Claude_Deliver :: struct {
	tab_id: u64,
	force:  bool,
}
Claude_Restore_History :: struct {
	records:      []Claude_Record,
	readonly_ids: []string, // conversations that ran read-only (claude_readonly_ids; outside the history's cap)
}
// The read-only profile loaded: its SessionStart hook (pi-desk's --settings) with this start's
// nonce (§1a). A Claude tab's own, once per start, before its first prompt.
Claude_Readonly_Ack :: struct {
	tab_id: u64,
	nonce:  string,
}

// ---- runtime (not State) ----

@(private = "file")
Claude_Rt :: struct {
	typed:     bool, // the user typed into the tab since its last submitted prompt
	enter_due: time.Tick, // a held text was pasted: Enter goes then
	// a read-only start (§1a): its profile must ack (Claude_Readonly_Ack) before the deadlines
	ro_need:   bool,
	ro_acked:  bool,
	ro_nonce:  [32]u8, // hex
	ro_due:    time.Tick, // its session report + CLAUDE_ACK_AFTER_SESSION ({} = none yet)
	ro_hard:   time.Tick, // its prompt up + CLAUDE_ACK_MAX ({} = not up yet: a startup dialog may be open)
}
@(private = "file")
claude_rt: map[u64]Claude_Rt

claude_tab_of :: proc(tab_id: u64) -> (s: ^Open_Session, tab: ^Tab, ct: ^Claude_Tab) {
	s, tab, _ = find_tab(tab_id)
	if tab == nil do return nil, nil, nil
	c, is := &tab.kind.(Claude_Tab)
	if !is do return nil, nil, nil
	return s, tab, c
}

// The user typed into a Claude tab (main.odin, keys and text that reach its terminal).
claude_note_typed :: proc(tab: ^Tab) {
	if tab == nil do return
	if _, is := tab.kind.(Claude_Tab); !is do return
	rt := claude_rt[tab.id]
	if !rt.typed {
		rt.typed = true
		claude_rt[tab.id] = rt
		app.redraw = true // the held strip says why it waits
	}
}

claude_typed :: proc(tab_id: u64) -> bool {return claude_rt[tab_id].typed}

// Whether a held text may go into the tab now: running, its turn idle per both signals (the
// hooks: Stop, or SessionStart; and Claude's own OSC 7501 program status when it reports one,
// agent_status.odin: neither working nor blocked), nothing typed since the user's last prompt,
// no Enter still due. Either signal alone can hold it back; OSC 7501 never stands in for hooks
// that have not said idle (never into a dialog).
claude_ready :: proc(tab: ^Tab, ct: ^Claude_Tab) -> (ok: bool, why: string) {
	if tab.status != .Running do return false, "Claude is not running in this tab"
	rt := claude_rt[tab.id]
	// a read-only start: nothing goes in before its profile acked (a prompt before it stops the tab)
	if rt.ro_need && !rt.ro_acked do return false, "Claude is starting (its read-only guard has not confirmed yet)"
	if rt.enter_due != {} do return false, "sending"
	switch ct.turn {
	case .Unknown: return false, "Claude is starting"
	case .Working: return false, "Claude is working"
	case .Waiting: return false, "Claude is waiting for you"
	case .Idle:
	}
	if v := tab_status_view(tab^); v.source == .Osc7501 {
		#partial switch v.state {
		case .Blocked: return false, "Claude is waiting for you"
		case .Working: return false, "Claude is working"
		}
	}
	if rt.typed do return false, "you are typing a message"
	if why := claude_paste_refused(tab); why != "" do return false, why
	return true, ""
}

// Held text goes only as a bracketed paste (Claude's prompt turns it on): without it each line
// would go as its own message and the Enter after it could answer a startup dialog (folder trust).
claude_paste_refused :: proc(tab: ^Tab) -> string {
	t := term_of(tab.id)
	if t == nil || !t.running do return "Claude is not running in this tab"
	if !mode_on(t, 2004) do return "Claude's input does not take pasted text now"
	return ""
}

// Why text from an agent cannot go into Claude's prompt as a message ("" = it can): Claude Code
// reads a first ! as a shell command, / as a slash command and # as a memory (& is refused too,
// in case a newer Claude Code gives it a meaning); control characters other than tab and newline
// (escapes, CR, DEL) never go into its terminal.
claude_command_text :: proc(text: string) -> string {
	for i in 0 ..< len(text) {
		c := text[i]
		if (c < 0x20 && c != '\t' && c != '\n') || c == 0x7f do return "text has control characters (only tab and newline may go)"
	}
	// an @file mention (a word starting @/, @~ or @.) would make Claude Code attach that file
	for i in 0 ..< len(text) - 1 {
		if text[i] != '@' || (i > 0 && !strings.is_space(rune(text[i - 1]))) do continue
		if n := text[i + 1]; n == '/' || n == '~' || n == '.' do return "@file mentions would attach files; send the path without @"
	}
	lead := strings.trim_left_space(text)
	if lead != "" && strings.index_byte("!/#&", lead[0]) >= 0 do return fmt.tprintf("text starting with %c would be a Claude Code command (! shell, / slash command, # memory): Deckhand sends only messages", lead[0])
	return ""
}


// Pastes text as the user's next message now, under the held-prompt rules (claude_ready: idle per
// hooks and OSC 7501, bracketed paste, nothing typed); Enter follows (claude_tick). "" = sent,
// else why not. pi-desk's own fixed text only (comments' Send now), never page or agent text.
// slash: pi-desk's own fixed slash command (CLAUDE_MODEL_COMMAND: Restart with model…), the one
// case a leading / may go in; never text from anyone else.
claude_paste_message :: proc(tab: ^Tab, text: string, slash := false) -> string {
	ct, is := &tab.kind.(Claude_Tab)
	if !is do return "not a Claude tab"
	if ok, why := claude_ready(tab, ct); !ok do return why
	if slash {
		if text != CLAUDE_MODEL_COMMAND do return "not Deckhand's own command"
	} else if why := claude_command_text(text); why != "" do return why
	t := term_of(tab.id)
	if t == nil || !t.running do return "Claude is not running in this tab"
	term_paste(t, text)
	ct.turn = .Working // until its hooks say otherwise
	rt := claude_rt[tab.id]
	rt.enter_due = time.tick_add(time.tick_now(), CLAUDE_ENTER_DELAY)
	rt.typed = false
	claude_rt[tab.id] = rt
	return ""
}

// Frame upkeep: a held text that can go is delivered (Claude_Deliver), its Enter follows the paste.
claude_tick :: proc() {
	claude_readonly_tick() // read-only starts whose profile never acked (§1a)
	for &s in state.open_sessions {
		for &tab in s.tabs {
			ct, is := &tab.kind.(Claude_Tab)
			if !is do continue
			rt := claude_rt[tab.id]
			if rt.enter_due != {} && time.tick_since(rt.enter_due) >= 0 {
				rt.enter_due = {}
				claude_rt[tab.id] = rt
				if t := term_of(tab.id); t != nil && t.running do pty_write(&t.pty, transmute([]u8)string("\r"))
				app.redraw = true
				continue
			}
			if len(ct.held) == 0 do continue
			if ok, _ := claude_ready(&tab, ct); ok do run_command(Claude_Deliver{tab_id = tab.id})
		}
	}
}

// ---- the plugin and the CLI ----

// The plugin folder pi-desk passes with --plugin-dir: PI_DESK_CLAUDE_PLUGIN (development), else
// the bundle's Contents/Resources/claude-code, else claude-code next to the binary (a bare
// build). "" = not found. Temp-allocated.
claude_plugin_dir :: proc() -> string {
	if p := os.get_env("PI_DESK_CLAUDE_PLUGIN", context.temp_allocator); p != "" && filepath.is_abs(p) && os.is_dir(p) do return p
	exe := executable_path()
	if exe == "" do return ""
	dir := filepath.dir(exe)
	for c in ([]string{"../Resources/claude-code", "claude-code"}) {
		p, _ := filepath.join({dir, c}, context.temp_allocator)
		if os.exists(strings.concatenate({p, "/.claude-plugin/plugin.json"}, context.temp_allocator)) do return p
	}
	return ""
}

// Tests: the CLI's path instead of the one next to the binary ("-" = none).
claude_cli_override: string

// The pi-desk-cli binary next to pi-desk's own ("" = missing). Temp-allocated.
claude_cli_path :: proc() -> string {
	if claude_cli_override != "" do return claude_cli_override == "-" ? "" : claude_cli_override
	exe := executable_path()
	if exe == "" do return ""
	p, _ := filepath.join({filepath.dir(exe), "pi-desk-cli"}, context.temp_allocator)
	return os.exists(p) ? p : ""
}

// claude, or why there is none (the shell's "command not found" says too little).
// Not on PATH: Claude Code's own install folders (~/.local/bin, the native
// installer's; ~/.claude/local, the older local install) are tried, after a
// line saying where it was found. Neither: what to do, exit 127.
CLAUDE_TAB_CMD :: `command -v claude >/dev/null 2>&1 || for d in "$HOME/.local/bin" "$HOME/.claude/local"; do case "$d" in /*) ;; *) continue;; esac; if [ -f "$d/claude" ] && [ -x "$d/claude" ]; then printf '%s\n' "Deckhand: Claude Code is installed at $d/claude but is not on your login shell's PATH; starting it from there. Add $d to PATH in your shell's login profile (~/.zprofile for zsh) so other tools find it too."; PATH="$d:$PATH"; export PATH; break; fi; done; command -v claude >/dev/null 2>&1 || { printf '%s\n' "Claude Code (claude) was not found: it is not on your login shell's PATH:" "  $PATH" "nor in ~/.local/bin or ~/.claude/local." "Install Claude Code, or add its folder to PATH in your shell's login profile (~/.zprofile for zsh, ~/.bash_profile for bash), then open a Claude tab again."; exit 127; }; exec claude "$@"`

// What a Claude tab runs: PI_DESK_CLAUDE_CMD (tests: a fake claude), else claude (CLAUDE_TAB_CMD);
// in test mode never the real claude: TEST_NO_CLAUDE_CMD (commands.odin).
claude_tab_cmd :: proc() -> string {
	if c := os.get_env("PI_DESK_CLAUDE_CMD", context.temp_allocator); c != "" do return c
	if test_mode() {
		test_mode_refused("claude")
		return TEST_NO_CLAUDE_CMD
	}
	return CLAUDE_TAB_CMD
}

// Starts claude in the tab's terminal: `$SHELL -l -c` (the user's PATH), --plugin-dir, --resume
// with the tab's session id when it has one, then its extra flags. The environment adds the
// socket, the tab's Claude token, the CLI's path and where screenshots go. PI_DESK_CLAUDE_CMD
// replaces claude (tests: a fake claude); it sees the same arguments as "$@". False if it could
// not start (the terminal says why). s: the tab's session (the tab may not be in it yet).
// Read-only (claude_tab_readonly; every start, whoever starts it): the user's flags only from
// the allowlist, pi-desk's profile last, PI_DESK_CLAUDE_READONLY=1; never without the guard.
// defaults: a start the user makes (a new tab, session or chat, the user's resume, restore and
// restart): the user's default flags as the setting is now (claude_with_defaults), never saved;
// a read-only start leaves them out and says so.
claude_start :: proc(s: ^Open_Session, t: ^Term, tab_id: u64, ct: ^Claude_Tab, cwd: string, flags := true, defaults := false) -> bool {
	plugin := claude_plugin_dir()
	if plugin == "" {
		term_note(t, "Deckhand's Claude Code plugin is missing from this build (integrations/claude-code): rebuild Deckhand.")
		return false
	}
	ro := claude_tab_readonly(s, ct)
	cli := claude_cli_path()
	nonce: string
	if ro {
		raw: [16]u8
		crypto.rand_bytes(raw[:])
		hx := "0123456789abcdef"
		b := make([]u8, 32, context.temp_allocator)
		for x, i in raw {
			b[2 * i] = hx[x >> 4]
			b[2 * i + 1] = hx[x & 15]
		}
		nonce = string(b)
	}
	if ro && cli == "" {
		term_note(t, "Deckhand's command (pi-desk-cli) is missing from this build, and a read-only Claude tab never starts without its guard: rebuild Deckhand.")
		return false
	}
	// its account (claude_accounts.odin): only a configured one starts
	if ct.account != "" && !claude_account_known(ct.account) {
		term_note(t, fmt.tprintf("This Claude tab's account (%s) is no longer in Settings → Claude accounts: add it again, then Restart.", path_tilde(ct.account)))
		return false
	}
	cmd := strings.concatenate({CLAUDE_ACCOUNT_SH, claude_tab_cmd()}, context.temp_allocator) // the account again after the login profile
	argv := shell_script_argv(login_shell(), cmd, "claude") // fish and co.: /bin/sh (commands.odin)
	append(&argv, "--plugin-dir", plugin)
	if ct.session_id != "" {
		// a transcript found on disk resumes by its path while it is still that conversation's file
		// under its account's projects/ (claude_disk.odin); else by id
		rp := ct.resume_path != "" ? claude_transcript_ok(ct.resume_path) : ""
		if rp != "" && strings.has_suffix(rp, strings.concatenate({"/", ct.session_id, ".jsonl"}, context.temp_allocator)) && path_kind(rp) == .File do append(&argv, "--resume", rp)
		else do append(&argv, "--resume", ct.session_id)
	}
	args := flags ? ct.args : nil // the user's; an agent's restart starts without them (§3)
	if defaults {
		with := claude_with_defaults(args)
		if !ro do args = with
		else if len(with) > len(args) do toast_show(fmt.tprintf("Read-only chat: %s (your default Claude Code flags) left out", strings.join(with[len(args):], " ", context.temp_allocator)))
	}
	if ro do args, _ = claude_readonly_args(args) // only the allowlist (saved from before it was read-only)
	append(&argv, ..args)
	if ro {
		ct.readonly = true // the tab's from now on (saved; kept by every later start)
		if r, _ := claude_record(ct.session_id); r != nil do r.readonly = true // and its conversation's (a resume from its row)
		claude_readonly_mark(ct.session_id)
		append(&argv, ..claude_readonly_profile(cli, nonce)) // last: nothing after it can loosen it
	}
	env := make([dynamic]string, context.temp_allocator)
	append(&env, ..pi_extra_env(socket_claude_env(tab_id, cli))) // + PI_KIT_NOTES_DIR, as pi tabs get it (folders.odin)
	append(&env, ..claude_account_env(ct.account)) // its account: CLAUDE_CONFIG_DIR (none for the default)
	if ro do append(&env, "PI_DESK_CLAUDE_READONLY=1")
	claude_shots_tidy()
	if !term_start(t, argv[:], cwd, env[:]) {
		socket_forget_tab(tab_id)
		return false
	}
	socket_claude_pid(tab_id, t.pty.pid)
	claude_wait_started(tab_id) // waits on its earlier run end (claude_wait.odin)
	ct.turn = .Unknown
	ct.ended = .None // a new process: how the last one's turn ended is gone
	rt := claude_rt[tab_id]
	rt = {}
	claude_rt[tab_id] = rt
	claude_work_reset(tab_id) // a new process: its todos and subagents start empty (claude_panels.odin)
	ct.guard_stopped = false
	if ro {
		// it must prove the profile loaded (its SessionStart hook acks this nonce)
		rt = claude_rt[tab_id]
		rt.ro_need = true
		copy(rt.ro_nonce[:], nonce)
		claude_rt[tab_id] = rt
	}
	return true
}

// Comment crops copied for Claude (comments_claude_take) that are over a day old go.
@(private = "file")
claude_shots_tidy :: proc() {
	dir := app_shots_dir(context.temp_allocator)
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	now := time.now()
	for f in files {
		if !strings.has_prefix(f.name, "comment-") || !strings.has_suffix(f.name, ".png") do continue
		if time.diff(f.modification_time, now) > 24 * time.Hour do os.remove(f.fullpath)
	}
}

// ---- read-only Claude (docs/CLAUDE.md §1a) ----

// The tools a read-only tab never gets (bare names: Claude Code takes them out of Claude's
// context, and no mode, allow rule or later flag can give them back). Bash stays, behind plan
// mode, the scoped deny rules below and the guard (`pi-desk hook readonly`).
CLAUDE_READONLY_DENY := [?]string {
	"Edit", "Write", "NotebookEdit", "MultiEdit", "PowerShell", "Monitor", "Agent", "Task", "Workflow",
	"CronCreate", "CronDelete", "ScheduleWakeup", "RemoteTrigger", "EnterWorktree", "ExitWorktree",
	"Artifact", "mcp__*", "ListMcpResourcesTool", "ReadMcpResourceTool", "ExitPlanMode",
}
// Scoped Bash deny rules for pi-kit's MUTATING programs (Claude Code applies a deny rule to every
// subcommand: a layer that holds if the guard does not run). Each as `Bash(x)` and `Bash(x *)`.
CLAUDE_READONLY_BASH_DENY := [?]string {
	"rm", "mv", "cp", "chmod", "chown", "touch", "mkdir", "tee", "sed -i", "git commit", "git push",
	"git merge", "git rebase", "git reset", "git checkout", "git switch", "git stash", "git apply",
	"git am", "git cherry-pick", "git revert", "git tag", "git worktree add", "git worktree remove",
	// pi-desk's own additions (the guard's m_pidesk)
	// (not git config: `Bash(git config *)` would block --get; the guard blocks its writes)
	"git clean", "git restore", "git pull", "git add", "git init", "git update-ref",
	"rmdir", "unlink", "ln", "truncate", "wget", "perl -i", "perl -pi",
}
CLAUDE_ACK_AFTER_SESSION :: 10 * time.Second // the ack after the session report (hooks run in parallel)
CLAUDE_ACK_MAX :: 120 * time.Second // the ack after Claude's prompt came up, whatever runs (no hook at all)
CLAUDE_READONLY_IDS_MAX :: 10_000 // least recently used first (claude_readonly_mark)
CLAUDE_GUARD_STOPPED :: "read-only guard not confirmed: stopped. A startup dialog may have been left open, or this Claude Code ignores Deckhand's settings (update it). Then Restart."

// The user's flags a read-only tab keeps (an allowlist: a list of the flags that would undo
// read-only would always miss one); each of these takes a value but --verbose.
CLAUDE_READONLY_KEEP := [?]string{"--model", "--effort", "--fallback-model"}
CLAUDE_READONLY_KEEP_BARE := [?]string{"--verbose"}

// A Claude tab in this session starts read-only: a chat while chats are read-only.
claude_chat_readonly :: proc(s: ^Open_Session) -> bool {
	return state.settings.chats_readonly && s != nil && open_session_is_chat(s)
}

// Whether a Claude tab starts read-only: it did before (the tab's, saved), its session is a chat
// while chats are read-only, or the conversation it resumes ran read-only.
claude_tab_readonly :: proc(s: ^Open_Session, ct: ^Claude_Tab) -> bool {
	if ct.readonly || claude_chat_readonly(s) do return true
	return claude_readonly_known(ct.session_id)
}

// Conversations that ran read-only, kept outside the history's cap (saved): a resume of one is
// read-only whatever else is known about it.
claude_readonly_known :: proc(id: string) -> bool {
	if id == "" do return false
	for x in state.claude_readonly_ids do if x == id do return true
	if r, _ := claude_record(id); r != nil && r.readonly do return true
	return false
}

// Marks a conversation read-only, as the most recently used (marked again: moved to the back);
// at the cap the least recently used goes.
claude_readonly_mark :: proc(id: string) {
	if id == "" || !claude_id_ok(id) do return
	if r, _ := claude_record(id); r != nil do r.readonly = true
	for x, i in state.claude_readonly_ids do if x == id {
		ordered_remove(&state.claude_readonly_ids, i)
		append(&state.claude_readonly_ids, x)
		return
	}
	append(&state.claude_readonly_ids, strings.clone(id))
	for len(state.claude_readonly_ids) > CLAUDE_READONLY_IDS_MAX do delete(pop_front(&state.claude_readonly_ids))
}

@(private = "file")
claude_readonly_listed :: proc(id: string) -> bool {
	for x in state.claude_readonly_ids do if x == id do return true
	return false
}

// A read-only start whose profile never acked: stopped (its process group killed, its token
// revoked). Not before: Claude cannot run a tool before its first prompt, and a prompt before the
// ack stops it at once (Claude_Turn_Report).
claude_readonly_tick :: proc(now := time.Tick{}) {
	n := now == {} ? time.tick_now() : now
	for &s in state.open_sessions {
		for &tab in s.tabs {
			ct, is := &tab.kind.(Claude_Tab)
			if !is || tab.status != .Running || ct.guard_stopped do continue
			rt := claude_rt[tab.id]
			if !rt.ro_need || rt.ro_acked do continue
			if rt.ro_hard == {} {
				// the clock starts once Claude's prompt is up (not while a trust, login or onboarding
				// dialog waits): bracketed paste on, or its OSC 7501 reporting other than blocked
				t := term_of(tab.id)
				up := t != nil && t.running && mode_on(t, 2004)
				if v := tab_status_view(tab); v.source == .Osc7501 && v.state != .Blocked do up = true
				if up {
					rt.ro_hard = time.tick_add(n, CLAUDE_ACK_MAX)
					claude_rt[tab.id] = rt
				}
			}
			late := (rt.ro_hard != {} && time.tick_diff(rt.ro_hard, n) > 0) || (rt.ro_due != {} && time.tick_diff(rt.ro_due, n) > 0)
			if late do claude_readonly_stop(&tab, ct)
		}
	}
}

// Whether pi-desk stopped this tab for an unconfirmed profile (tests, the label).
claude_readonly_stopped :: proc(tab_id: u64) -> bool {
	_, _, ct := claude_tab_of(tab_id)
	return ct != nil && ct.guard_stopped
}

@(private = "file")
claude_readonly_stop :: proc(tab: ^Tab, ct: ^Claude_Tab) {
	ct.guard_stopped = true
	held_clear(ct)
	socket_forget_tab(tab.id) // nothing more from its token
	if t := term_of(tab.id); t != nil {
		term_note(t, CLAUDE_GUARD_STOPPED)
		if t.pty.pid > 0 do posix.killpg(posix.pid_t(t.pty.pid), .SIGKILL) // claude and what it runs
	}
	toast_show("A read-only Claude was stopped: its guard was not confirmed (a startup dialog left open, or an old Claude Code)", err = true)
	app.redraw = true
}

// The user's flags a read-only tab keeps (temp), and the first one it does not ("" = none).
claude_readonly_args :: proc(args: []string) -> (kept: []string, refused: string) {
	out := make([dynamic]string, 0, len(args), context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		name := a
		if j := strings.index_byte(a, '='); j > 0 do name = a[:j]
		bare := false
		for k in CLAUDE_READONLY_KEEP_BARE do if a == k do bare = true
		valued := false
		for k in CLAUDE_READONLY_KEEP do if name == k do valued = true
		switch {
		case bare, valued && name != a:
			append(&out, a)
		case valued && i + 1 < len(args) && !strings.has_prefix(args[i + 1], "-"):
			append(&out, a, args[i + 1])
			i += 1
		case:
			if refused == "" do refused = name // the flag's name only: its value may be anything (a JSON of settings)
		}
	}
	return out[:], refused
}

// Why these flags cannot go to a read-only tab ("" = they can).
claude_readonly_refusal :: proc(args: []string) -> string {
	if _, bad := claude_readonly_args(args); bad != "" do return fmt.tprintf("%s cannot go into a read-only chat (only --model, --effort, --fallback-model and --verbose go along; Chats: read-only is on)", bad)
	return ""
}

// s in single quotes for sh (temp).
claude_sh_quote :: proc(s: string) -> string {
	q, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return strings.concatenate({"'", q, "'"}, context.temp_allocator)
}

// The guard's command line: the CLI by its absolute path (nothing from the environment); any
// failure of it (missing, crashed, exit 1) becomes exit 2, which blocks the call.
claude_readonly_hook_command :: proc(cli: string) -> string {
	return strings.concatenate({claude_sh_quote(cli), " hook readonly || exit 2"}, context.temp_allocator)
}

// The settings pi-desk passes with --settings (above the user's and the project's; not kept by
// --resume, so passed at every start): plan mode, the deny rules, no bypass or auto mode, hooks
// on (a project's disableAllHooks cannot turn the guard off), no shell in skills, and the guard
// for every tool call, blocking when it fails or times out.
claude_readonly_settings :: proc(cli, nonce: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"permissions":{"defaultMode":"plan","disableBypassPermissionsMode":"disable","disableAutoMode":"disable","deny":[`)
	n := 0
	rule :: proc(b: ^strings.Builder, n: ^int, r: string) {
		if n^ > 0 do strings.write_byte(b, ',')
		json_quote(b, r)
		n^ += 1
	}
	for d in CLAUDE_READONLY_DENY do rule(&b, &n, d)
	for d in CLAUDE_READONLY_BASH_DENY {
		rule(&b, &n, fmt.tprintf("Bash(%s)", d))
		rule(&b, &n, fmt.tprintf("Bash(%s *)", d))
	}
	strings.write_string(&b, `]},"disableAllHooks":false,"disableSkillShellExecution":true,"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":`)
	json_quote(&b, claude_readonly_hook_command(cli))
	strings.write_string(&b, `,"timeout":30,"onFailure":"block"}]}],"SessionStart":[{"hooks":[{"type":"command","command":`)
	json_quote(&b, strings.concatenate({claude_sh_quote(cli), " hook readonly-ack ", nonce}, context.temp_allocator))
	strings.write_string(&b, `,"timeout":30}]}]}}`)
	return strings.to_string(b)
}

// pi-desk's read-only profile, last in argv (temp): plan mode, the user's settings files only (a
// project's settings, hooks and .mcp.json in the chats folder are not loaded), pi-desk's settings,
// and the denied tools.
claude_readonly_profile :: proc(cli, nonce: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, "--permission-mode", "plan", "--setting-sources", "user", "--settings", claude_readonly_settings(cli, nonce), "--disallowedTools")
	append(&out, ..CLAUDE_READONLY_DENY[:])
	return out[:]
}

// What a read-only tab's token may not send (pi-desk's own check, whatever the guard let
// through): acting on a page or an app. Reading, screenshots and navigation stay, as for pi.
claude_readonly_refuses :: proc(caller: Caller, cmd: Command) -> string {
	if caller.kind != .Panel || !caller.claude do return ""
	#partial switch _ in cmd {
	case Browser_Click, Browser_Type, Browser_Press, Browser_Select, Browser_Upload, Browser_Hover, App_Input, App_Call, New_App_Tab, App_Restart, App_Close: // hover too: it can fire a page's scripts
	case:
		return ""
	}
	_, _, ct := claude_tab_of(caller.tab_id)
	if ct == nil || !ct.readonly do return ""
	return "a read-only chat's Claude may read pages and apps, not act on them (Chats: read-only is on)"
}

// ---- is Claude Code installed? ----

// Whether `claude` is there, cached (claude_installed). Unknown = look again at the next use.
Claude_Found :: enum u8 {
	Unknown,
	Yes,
	No,
}
claude_found: Claude_Found

// What the user sees when Claude Code is not installed: how to install it (code.claude.com/docs/en/setup).
CLAUDE_MISSING :: "Claude Code is not installed: install it with `curl -fsSL https://claude.ai/install.sh | bash` (or `brew install --cask claude-code`; npm or a managed install: code.claude.com/docs/en/setup), then use Refresh shell environment or restart Deckhand"
// The note a menu row's label gets meanwhile ("New Claude tab — Claude Code not installed").
CLAUDE_MISSING_NOTE :: " — Claude Code not installed"

// Whether a `claude` that can run is on `path` (absolute entries only) or where its installers put
// it (<home>/.local/bin, <home>/.claude/local; the places the tab's command also tries). By stat
// and access(X_OK) only: claude is never run to find out.
claude_detect :: proc(path, home: string) -> bool {
	for dir in strings.split(path, ":", context.temp_allocator) do if exe_in(dir, "claude") do return true
	if filepath.is_abs(home) {
		for d in ([]string{".local/bin", ".claude/local"}) do if exe_in(strings.concatenate({home, "/", d}, context.temp_allocator), "claude") do return true
	}
	return false
}

// Whether Claude Code is installed, as new tabs would find it: the PATH new children get
// (child_base_env: after Refresh shell environment, the refreshed one) and HOME. Cached;
// claude_recheck drops the cache (a refresh, a Claude tab that exited 127, the user's click).
claude_installed :: proc() -> bool {
	if claude_installed_probe != nil do return claude_installed_probe()
	if claude_found == .Unknown do claude_found = claude_detect(detect_path(), os.get_env("HOME", context.temp_allocator)) ? .Yes : .No // test mode: not PATH (harness.odin)
	return claude_found == .Yes
}

claude_recheck :: proc() {claude_found = .Unknown}

// claude_installed, with a cached "no" looked up again first: what a user's action asks (a Restart,
// a click, a session shown: the user may have installed it since).
claude_installed_now :: proc() -> bool {
	if claude_found == .No do claude_recheck()
	return claude_installed()
}

// Tests: stands in for the lookup (claude_extras_test.odin); nil = look.
claude_installed_probe: proc() -> bool

// A command that would start claude when it is not installed: the user is told how to install it
// (the user may have just installed it: a cached "no" is looked up again first); everyone gets the
// same refusal.
claude_missing :: proc(caller: Caller) -> (r: Result, missing: bool) {
	if caller.kind == .UI ? claude_installed_now() : claude_installed() do return {}, false
	if caller.kind == .UI do toast_show(CLAUDE_MISSING, err = true)
	return fail(CLAUDE_MISSING), true
}

// A menu or palette label, with the note while Claude Code is not installed (temp).
claude_label :: proc(label: string) -> string {
	if claude_installed() do return label
	return strings.concatenate({label, CLAUDE_MISSING_NOTE}, context.temp_allocator)
}

// ---- checks ----

// A Claude session id as Claude Code makes them (a UUID): letters, digits and '-', not
// starting with '-' (it goes into argv after --resume).
claude_id_ok :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > 64 || id[0] == '-' do return false
	for ch in transmute([]u8)id do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-') do return false
	return true
}

// Why these extra flags cannot go ("" = they can): flags pi-desk sets itself, and the ones that
// pick another session, are refused; no NUL or line breaks; at most CLAUDE_ARGS_MAX.
claude_args_check :: proc(args: []string) -> string {
	if len(args) > CLAUDE_ARGS_MAX do return fmt.tprintf("at most %d extra flags", CLAUDE_ARGS_MAX)
	own := [?]string{"--plugin-dir", "--resume", "-r", "--continue", "-c", "--session-id", "--fork-session", "--print", "-p"}
	for a in args {
		if a == "" || len(a) > 1024 || strings.contains_any(a, "\x00\r\n") do return "an extra flag is empty, too long or has a line break"
		name := a
		if i := strings.index_byte(a, '='); i > 0 do name = a[:i]
		for o in own do if name == o do return fmt.tprintf("%s is Deckhand's to set", o)
	}
	return ""
}

// The user's default flags (Settings, the Claude Code group: "Default Claude Code flags for new
// tabs"; off by default). Temp.
claude_default_args :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if state.settings.claude_skip_permissions do append(&out, "--dangerously-skip-permissions")
	return out[:]
}

// What turning skip-permissions on asks the user (Set_Claude_Default_Flags).
CLAUDE_SKIP_CONFIRM :: "Start the Claude tabs you start with --dangerously-skip-permissions? Claude will edit files and run commands without asking you first. Agents' tabs and read-only chats never get it."

// args with the user's default flags as the setting is NOW, after them (claude_start, for a
// start the user makes: never saved into a tab's or a record's flags, so turning the setting off
// takes it away from every later start). A default is left out when args already name it, and
// skipping permissions when they set a permission mode; all of them when they would go past
// CLAUDE_ARGS_MAX (silently: the tab starts with its own flags). Temp.
claude_with_defaults :: proc(args: []string) -> []string {
	defaults := claude_default_args()
	if len(defaults) == 0 do return args
	given :: proc(args: []string, names: ..string) -> bool {
		for a in args {
			name := a
			if i := strings.index_byte(a, '='); i > 0 do name = a[:i]
			for n in names do if name == n do return true
		}
		return false
	}
	list := make([dynamic]string, 0, len(args) + len(defaults), context.temp_allocator)
	append(&list, ..args)
	for d in defaults {
		if given(args, d) do continue
		if d == "--dangerously-skip-permissions" && given(args, "--permission-mode", "--allow-dangerously-skip-permissions") do continue
		append(&list, d)
	}
	if len(list) > CLAUDE_ARGS_MAX do return args
	return list[:]
}

// ---- history ----

claude_record :: proc(id: string) -> (^Claude_Record, int) {
	for &r, i in state.claude_history do if r.id == id do return &r, i
	return nil, -1
}

@(private = "file")
record_free :: proc(r: Claude_Record) {
	delete(r.id)
	delete(r.cwd)
	delete(r.project)
	delete(r.title)
	for a in r.args do delete(a)
	delete(r.args)
	delete(r.transcript)
	delete(r.model)
	delete(r.account)
}

@(private = "file")
clone_strings :: proc(list: []string) -> []string {
	out := make([]string, len(list))
	for a, i in list do out[i] = strings.clone(a)
	return out
}

// The session id (and where it ran) goes to the front of the history; its title and flags stay.
@(private = "file")
history_touch :: proc(id, cwd, project: string, args: []string, readonly: bool, account: string) {
	// every entry records its account's folder (the default's when the tab has none)
	rec := Claude_Record{id = strings.clone(id), cwd = strings.clone(cwd), project = strings.clone(project), used = time.now()._nsec / 1e9, args = clone_strings(args), readonly = readonly, account = strings.clone(claude_account_dir(account))}
	if old, i := claude_record(id); old != nil {
		// its account stays (its transcript is in that folder)
		if old.account != "" {
			delete(rec.account)
			rec.account = strings.clone(old.account)
		}
		rec.title = strings.clone(old.title)
		rec.readonly ||= old.readonly // once read-only, its resumes are read-only too
		rec.named = old.named
		rec.transcript = strings.clone(old.transcript)
		rec.model = strings.clone(old.model)
		// its flags stay the ones it was first run with (an agent's resume runs without the
		// permission flags: the user's own resume still has them)
		for a in rec.args do delete(a)
		delete(rec.args)
		rec.args = clone_strings(old.args)
		record_free(old^)
		ordered_remove(&state.claude_history, i)
	}
	inject_at(&state.claude_history, 0, rec)
	for len(state.claude_history) > CLAUDE_HISTORY_MAX do record_free(pop(&state.claude_history))
}

// The tab running Claude session `id`, 0 = none.
// Whether `id` is not this tab's to report (claude.session): a pi session's (listed, its file in
// the tab's project, or an open session's: a prompt-injected Claude reporting its pi session's id
// would turn the pi row into a Claude resume), or a Claude session another tab runs (a /resume to
// a conversation open elsewhere: two sessions would share one key). Its own id again is fine.
@(private = "file")
claude_id_taken :: proc(s: ^Open_Session, tab: ^Tab, p: ^Project, id: string) -> bool {
	if session_listed(state.sessions[:], id) || session_listed(state.chats[:], id) do return true
	if p != nil && p.group == .Projects && find_session_file(p^, id) != "" do return true
	main := tab != nil && s.agent == .Claude && s.tabs[0].id == tab.id // tab nil: a tab to be opened
	for &o in state.open_sessions {
		if o.home || o.pi_session_id != id do continue
		if !(main && o.id == s.id) do return true
	}
	if other := claude_tab_of_session(id); other != 0 && (tab == nil || other != tab.id) do return true
	return false
}

// The tab holding Claude session `id`, whatever its state (exited, not started too); 0 = none.
// Claude session `id` resumed where its tab already is (any state): never a second tab for one
// conversation. A dead one starts again in place (the user's saved flags only for the user, §3);
// one not started yet (restored) starts when the user shows it (focus_session). The user's and
// scripts' come to the front. open = false: no tab holds it.
claude_resume_open :: proc(id: string, caller: Caller) -> (r: Result, open: bool) {
	tid := claude_tab_of_session(id)
	if tid == 0 do return {}, false
	s, tab, _ := find_tab(tid)
	if tab.status == .Exited {
		if restart_waiting(tab.id) do return fail("this tab is restarting"), true // never an agent's flagless restart over the user's
		if s.missing do return fail("this session is gone"), true
		if mr, missing := claude_missing(caller); missing do return mr, true
		if rr := claude_tab_restart(s, tab, caller.kind == .UI); !rr.ok do return rr, true
	}
	if caller.kind == .UI || caller.kind == .Script do run_command(Focus_Tab{tab_id = tid}, {kind = caller.kind == .UI ? .UI : .Internal})
	return {ok = true, created_id = tid}, true
}

claude_tab_of_session :: proc(id: string) -> u64 {
	if id == "" do return 0
	for s in state.open_sessions do for tab in s.tabs do if ct, is := tab.kind.(Claude_Tab); is && ct.session_id == id do return tab.id
	return 0
}

claude_open_tab :: proc(id: string) -> u64 {
	for s in state.open_sessions do for tab in s.tabs do if ct, is := tab.kind.(Claude_Tab); is && ct.session_id == id && tab.status != .Exited do return tab.id
	return 0
}

// ---- where a tab opens ----

// The open session a Claude tab of project `p` goes into: the session on screen if it is the
// project's, else the project's most recently shown open session; nil = none open.
@(private = "file")
claude_host :: proc(p: ^Project) -> ^Open_Session {
	if cs := cur(); cs != nil && !cs.home && cs.project_id == p.id do return cs
	best: ^Open_Session
	for &s in state.open_sessions {
		if s.home || s.missing || s.project_id != p.id do continue
		if best == nil || s.shown_at > best.shown_at do best = &s
	}
	return best
}

// Opens a Claude tab in s. focus: the user's and scripts' tabs come to the front; an agent's
// open behind (an agent never changes what the user sees).
@(private = "file")
claude_open :: proc(s: ^Open_Session, cwd, resume: string, args: []string, caller: Caller, account: string, resume_path := "") -> (Result, bool) {
	focus := caller.kind == .UI || caller.kind == .Script
	tab := Tab{id = new_id(), kind = Claude_Tab{session_id = strings.clone(resume), args = clone_strings(args), account = strings.clone(account), resume_path = strings.clone(resume_path)}, title = strings.clone("Claude"), status = .Running}
	if cwd != s.cwd do tab.cwd = strings.clone(cwd)
	ct := &tab.kind.(Claude_Tab)
	t := new_term(tab.id)
	if !claude_start(s, t, tab.id, ct, cwd, defaults = caller.kind == .UI) { // the user's: with the default flags
		drop_term(tab.id)
		tab_free_kind(&tab)
		delete(tab.title)
		delete(tab.cwd)
		return fail("could not start Claude Code"), false
	}
	append(&s.tabs, tab)
	if focus {
		s.active_tab = tab.id
		focus_session(s.id, caller)
	}
	if resume != "" {
		p := find_project(s.project_id)
		history_touch(resume, cwd, p != nil ? p.cwd : s.cwd, args, ct.readonly, account)
	}
	// the next new session's default (claude_account_pick); the user's own choice
	if caller.kind == .UI && account != "" && account != state.settings.claude_account_last {
		delete(state.settings.claude_account_last)
		state.settings.claude_account_last = strings.clone(account)
	}
	return {ok = true, created_id = tab.id}, true
}

// A Claude-only session in project p: its main tab runs claude in cwd (resuming `resume` when
// given). focus: the user's and scripts' come to the front; an agent's open behind. created_id =
// the session.
@(private = "file")
claude_open_session :: proc(p: ^Project, cwd, resume: string, args: []string, caller: Caller, account: string, resume_path := "") -> (Result, bool) {
	append(&state.open_sessions, Open_Session{id = new_id(), agent = .Claude, project_id = p.id, cwd = strings.clone(p.cwd), pi_session_id = strings.clone(resume)})
	s := &state.open_sessions[len(state.open_sessions) - 1]
	id := s.id
	r, _ := claude_open(s, cwd, resume, args, caller, account, resume_path)
	s = find_session(id)
	if !r.ok {
		delete(s.cwd)
		delete(s.pi_session_id)
		delete(s.tabs)
		pop(&state.open_sessions)
		return r, false
	}
	s.active_tab = r.created_id
	return {ok = true, created_id = id}, true
}

// A transcript found on disk (claude_disk.odin) resumed in a Claude-only session of p under its
// account, by its path, with no flags (it has none). created_id = the session.
claude_open_disk :: proc(p: ^Project, f: Claude_Disk, caller: Caller) -> (Result, bool) {
	if claude_open_tab(f.id) != 0 || claude_tab_of_session(f.id) != 0 do return fail("that conversation is open in a tab"), false
	return claude_open_session(p, p.cwd, f.id, nil, caller, f.account, f.path)
}

// Where a Claude session of the history runs again: the folder it ran in while that is still
// inside its project, else the project's (temp).
@(private = "file")
claude_resume_cwd :: proc(rec: ^Claude_Record, p: ^Project, s: ^Open_Session = nil) -> string {
	if rec.cwd != "" && os.is_dir(rec.cwd) {
		at := fs_real(rec.cwd)
		if within(at, fs_real(p.cwd)) || (s != nil && within(at, fs_real(s.cwd))) do return at
		if wt_checkout_err(p.cwd, at, listed = false) == "" do return at // a worktree it ran in (its New session here, Claude Code picked)
	}
	return s != nil ? s.cwd : p.cwd
}

// A saved Claude-only session back (Restore_Session with agent claude), not started: its main
// Claude tab first (its Claude session id is the session's), then its other tabs. A gone project
// folder: "gone", never started.
claude_restore_session :: proc(p: ^Project, c: Restore_Session) -> (Result, bool) {
	if !claude_id_ok(c.pi_session_id) do return fail("not a Claude session id"), false
	if len(c.tabs) == 0 || c.tabs[0].kind != .Claude || c.tabs[0].claude_id != c.pi_session_id || claude_args_check(c.tabs[0].args) != "" do return fail("a Claude session's first tab is its Claude tab"), false
	if claude_open_tab(c.pi_session_id) != 0 do return fail("this session is already open"), false
	s := Open_Session{agent = .Claude, pi_session_id = strings.clone(c.pi_session_id), project_id = p.id, cwd = strings.clone(p.cwd), restored = true, missing = !os.is_dir(p.cwd)}
	restore_tabs(&s, c.tabs)
	s.id = new_id()
	if s.active_tab == 0 do s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	return {ok = true, created_id = s.id}, true
}

// Frees a Claude tab's own data (its kind's strings and held texts).
tab_free_kind :: proc(tab: ^Tab) {
	ct, is := &tab.kind.(Claude_Tab)
	if !is do return
	delete(ct.session_id)
	delete(ct.model)
	delete(ct.account)
	delete(ct.resume_path)
	for a in ct.args do delete(a)
	delete(ct.args)
	for h in ct.held {
		delete(h.text)
		delete(h.who)
	}
	delete(ct.held)
	ct^ = {}
	delete_key(&claude_rt, tab.id)
	claude_work_reset(tab.id) // its todos and subagents (claude_panels.odin)
}

@(private = "file")
held_clear :: proc(ct: ^Claude_Tab) {
	for h in ct.held {
		delete(h.text)
		delete(h.who)
	}
	clear(&ct.held)
}

// The tab's process exited, or it is closing: what it held goes; its history entry is used now.
claude_tab_gone :: proc(tab: ^Tab) {
	ct, is := &tab.kind.(Claude_Tab)
	if !is do return
	held_clear(ct)
	ct.turn = .Unknown
	ct.ended = .None
	delete_key(&claude_rt, tab.id)
	claude_work_reset(tab.id) // its panels went with the exit (Tab_Exited)
	if r, _ := claude_record(ct.session_id); r != nil do r.used = time.now()._nsec / 1e9
}

@(private = "file")
caller_label :: proc(caller: Caller) -> string {
	#partial switch caller.kind {
	case .UI:      return "you"
	case .Control: return agent_name()
	case .Script:  return "a script"
	}
	return "Deckhand"
}

// ---- apply ----

claude_apply :: proc(cmd: Command, caller: Caller, request_id: u64) -> (r: Result, changed: bool) {
	#partial switch c in cmd {
	case New_Claude_Tab:
		if mr, missing := claude_missing(caller); missing do return mr, false
		s: ^Open_Session
		if c.session != 0 {
			s = find_session(c.session)
			if s == nil do return fail("no such session"), false
		} else if c.project_id != 0 {
			p := find_project(c.project_id)
			if p == nil do return fail("no such project"), false
			if p.group == .Chats do return fail(CHATS_NOT_A_PROJECT), false
			s = claude_host(p)
			if s == nil {
				// no session of the project is open: a new one holds the tab
				rr, ch := open_new_session(p^, new_uuid(), "")
				if !rr.ok do return rr, ch
				s = find_session(rr.created_id)
			}
		} else do return fail("session or project_id is needed"), false
		if s.home do return fail("Home has only its pi tab"), false
		if s.missing do return fail("this session is gone"), false
		if len(c.args) > 0 && caller.kind != .UI && caller.kind != .Script && caller.kind != .Internal do return fail("only the user sets Claude Code's flags"), false
		if e := claude_args_check(c.args); e != "" do return fail(e), false
		// read-only (a chat while chats are, or a conversation that ran read-only): the allowlist
		ro := claude_chat_readonly(s)
		if claude_readonly_known(c.resume) do ro = true
		if ro do if e := claude_readonly_refusal(c.args); e != "" do return fail(e), false
		if c.resume != "" {
			if !claude_id_ok(c.resume) do return fail("resume must be a Claude session id"), false
			if r, open := claude_resume_open(c.resume, caller); open do return r, r.ok
			// a pi session's id, or another open session's key: never resumed as Claude
			if claude_id_taken(s, nil, find_project(s.project_id), c.resume) do return fail("that id is another session's"), false
		}
		cwd := s.cwd
		if c.cwd != "" {
			p, _, err := fs_check(c.cwd, caller, allow_root = true)
			if err != "" && wt_known_checkout(fs_abs(c.cwd, caller)) do p, err = fs_real(fs_abs(c.cwd, caller)), ""
			if err != "" do return fail(err), false
			if path_kind(p) != .Dir do return fail("not a folder"), false
			pr := find_project(s.project_id)
			if !within(p, fs_real(s.cwd)) && (pr == nil || !within(p, fs_real(pr.cwd))) do return fail("cwd must be inside the session's project"), false
			cwd = p
		}
		// its account: the one named (configured only), else the resumed entry's, else the default pick
		account, aerr := claude_account_resolve(c.account)
		if aerr != "" do return fail(aerr), false
		// a recorded session stays in its account: its transcript is there
		if rec, _ := claude_record(c.resume); rec != nil && c.resume != "" {
			ra := claude_account_dir(rec.account)
			if !claude_account_known(ra) do return fail("its Claude account is no longer in Settings → Claude accounts"), false
			if account != "" && account != ra && fs_real(account) != fs_real(ra) do return fail(fmt.tprintf("that Claude session belongs to the account %s", claude_account_label_now(ra) != "" ? claude_account_label_now(ra) : path_tilde(ra))), false
			account = ra
		}
		if account == "" do account = claude_account_pick(find_project(s.project_id))
		return claude_open(s, cwd, c.resume, c.args, caller, account)
	case New_Claude_Session:
		p := find_project(c.project_id)
		if p == nil do return fail("no such project"), false
		// in Chats too: a Claude chat (read-only while chats are: claude_chat_readonly); the chats
		// folder is made at the first chat, as for pi's (open_new_session)
		if p.group == .Chats && !p.missing && !os.exists(p.cwd) {
			os.make_directory_all(p.cwd)
			chats_instructions_ensure(date_stamp())
		}
		if p.missing || !os.is_dir(p.cwd) do return fail("the project's folder is gone"), false
		if len(c.args) > 0 && caller.kind != .UI && caller.kind != .Script && caller.kind != .Internal do return fail("only the user sets Claude Code's flags"), false
		if e := claude_args_check(c.args); e != "" do return fail(e), false
		if p.group == .Chats && state.settings.chats_readonly do if e := claude_readonly_refusal(c.args); e != "" do return fail(e), false
		cwd := p.cwd
		if c.cwd != "" {
			at, _, err := fs_check(c.cwd, caller, allow_root = true)
			if err != "" && wt_known_checkout(fs_abs(c.cwd, caller)) do at, err = fs_real(fs_abs(c.cwd, caller)), ""
			if err != "" do return fail(err), false
			if path_kind(at) != .Dir do return fail("not a folder"), false
			// inside the project, or a checkout of its repository (a worktree's New session here, Claude Code picked)
			if !within(at, fs_real(p.cwd)) && wt_checkout_err(p.cwd, at, listed = true) != "" do return fail("cwd must be inside the project or one of its repository's checkouts"), false
			cwd = at
		}
		if mr, missing := claude_missing(caller); missing do return mr, false
		account, aerr := claude_account_resolve(c.account)
		if aerr != "" do return fail(aerr), false
		if account == "" do account = claude_account_pick(p)
		return claude_open_session(p, cwd, "", c.args, caller, account)
	case Claude_Rename:
		rec, _ := claude_record(c.claude_session_id)
		if rec == nil do return fail("no such Claude session in Deckhand's history"), false
		title := cut_utf8(strings.trim_space(one_line(c.title, context.temp_allocator)), CLAUDE_TITLE_MAX)
		if title == rec.title do return {ok = true}, false
		delete(rec.title)
		rec.title = strings.clone(title)
		rec.named = title != "" // the user's own: pushed to Claude Code at its next start (claude_rows.odin)
		return {ok = true}, true
	case Claude_Resume:
		// a session of the history again: an open one is focused (its tab, wherever it is); else it
		// resumes in a Claude-only session of its project. created_id = its Claude tab
		rec, _ := claude_record(c.claude_session_id)
		if rec == nil do return fail("no such Claude session in Deckhand's history"), false
		if r, open := claude_resume_open(rec.id, caller); open do return r, r.ok
		p := project_by_cwd(rec.project)
		if ch := chats_project(); p == nil && ch != nil && ch.cwd == rec.project do p = ch // a Claude chat
		if p == nil do return fail("its project is not listed"), false
		if mr, missing := claude_missing(caller); missing do return mr, false
		// under the account it ran in, while that is configured (never another account's folder)
		if !claude_account_known(rec.account) do return fail(fmt.tprintf("its Claude account (%s) is no longer in Settings → Claude accounts", path_tilde(claude_account_dir(rec.account)))), false
		account := claude_account_dir(rec.account)
		cwd := claude_resume_cwd(rec, p)
		id := strings.clone(rec.id, context.temp_allocator)
		args := make([]string, len(rec.args), context.temp_allocator)
		for a, i in rec.args do args[i] = strings.clone(a, context.temp_allocator)
		// the saved flags are the user's to replay: anyone else's resume (Atlas, a script) starts
		// claude with only the plugin and --resume (a flag denylist would always miss one)
		if caller.kind != .UI do args = nil
		r, ch := claude_open_session(p, cwd, id, args, caller, account)
		if !r.ok do return r, ch
		return {ok = true, created_id = find_session(r.created_id).tabs[0].id}, true
	case Claude_Session_Report:
		s, tab, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		if !claude_id_ok(c.session_id) do return fail("session_id must be a Claude session id"), false
		p := find_project(s.project_id)
		project := p != nil ? p.cwd : s.cwd
		if rec, _ := claude_record(c.session_id); rec != nil && rec.project != project do return fail("that Claude session belongs to another project"), false
		if claude_id_taken(s, tab, p, c.session_id) do return fail("that id is another session's"), false
		if ct.session_id != c.session_id {
			delete(ct.session_id)
			ct.session_id = strings.clone(c.session_id)
		}
		// a Claude-only session is known by its main tab's Claude session (pins, rows, the bell)
		if s.agent == .Claude && s.tabs[0].id == tab.id && s.pi_session_id != c.session_id {
			delete(s.pi_session_id)
			s.pi_session_id = strings.clone(c.session_id)
		}
		cwd := tab.cwd != "" ? tab.cwd : s.cwd
		history_touch(c.session_id, cwd, project, ct.args, ct.readonly, ct.account)
		if ct.readonly do claude_readonly_mark(c.session_id) // a new conversation of a read-only tab (/clear) too
		if rt := claude_rt[tab.id]; rt.ro_need && !rt.ro_acked && rt.ro_due == {} {
			rt.ro_due = time.tick_add(time.tick_now(), CLAUDE_ACK_AFTER_SESSION)
			claude_rt[tab.id] = rt
		}
		claude_work_session(tab, c.source) // a new conversation: its todos and subagents start empty
		return {ok = true, data = claude_rows_session(ct, c)}, true // transcript, model; the user's title back (claude_rows.odin)
	case Claude_Turn_Report:
		ts, tab, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		was := ct.turn
		defer if claude_status_turn(ts, tab, was, c.state, c.idle_prompt) do app.redraw = true // dots without OSC 7501 (claude_status.odin)
		ended := claude_rows_turn(ct, c.state, c.question, c.idle_prompt) // the question and error dots (claude_rows.odin)
		switch c.state {
		case "submitted":
			// a prompt before the read-only profile acked: it never loaded (§1a): stopped now
			if rt := claude_rt[tab.id]; rt.ro_need && !rt.ro_acked && !ct.guard_stopped {
				claude_readonly_stop(tab, ct)
				return {ok = true}, true
			}
			ct.turn = .Working
			rt := claude_rt[tab.id]
			rt.typed = false // the prompt the user typed went: the input is empty again
			claude_rt[tab.id] = rt
			claude_work_submitted(tab) // finished subagents leave its panel
			if r, _ := claude_record(ct.session_id); r != nil {
				r.used = time.now()._nsec / 1e9 // its row's "last active"
				if r.title == "" && c.title != "" do r.title = strings.clone(cut_utf8(strings.trim_space(one_line(c.title, context.temp_allocator)), CLAUDE_TITLE_MAX))
				return {ok = true}, true
			}
		case "idle", "error": ct.turn = .Idle // StopFailure ends the turn too
		case "waiting":       ct.turn = .Waiting
		case:                 return fail("state must be submitted, idle, error or waiting"), false
		}
		return {ok = true}, ct.turn != was || ended
	case Claude_Comments:
		s, _, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		limit := c.max <= 0 ? CLAUDE_COMMENTS_MAX : min(c.max, CLAUDE_COMMENTS_MAX)
		return comments_claude_take(s, max(limit, 4000)), false
	case Claude_Attached:
		s, _, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		return {ok = true}, comments_claude_attached(s, c.attachment_id)
	case Claude_Prompt:
		_, tab, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		if owns_tab(caller, c.tab_id) do return fail("a caller cannot act on its own tab"), false
		if tab.status != .Running do return fail("Claude is not running in this tab"), false
		text := strings.trim_right(c.text, " \t\r\n")
		if text == "" do return fail("text is empty"), false
		if why := claude_command_text(text); why != "" do return fail(why), false
		if len(text) > CLAUDE_PROMPT_MAX do return fail(fmt.tprintf("text is over %d KB", CLAUDE_PROMPT_MAX / 1024)), false
		if len(ct.held) >= CLAUDE_HELD_MAX do return fail(fmt.tprintf("%d texts already wait for this Claude tab", CLAUDE_HELD_MAX)), false
		hid := claude_held_id()
		append(&ct.held, Claude_Held{id = hid, text = strings.clone(text), who = strings.clone(caller_label(caller))})
		claude_timer_kick() // delivered even while frames are paused (claude_wait.odin)
		_, why := claude_ready(tab, ct)
		return {ok = true, data = fmt.tprintf(`{{"held":%d,"waits":%q,"id":%d}}`, len(ct.held), why, hid)}, true
	case Claude_Held_Op:
		_, tab, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		switch c.op {
		case "drop":
			if len(ct.held) == 0 do return {ok = true}, false
			for h in ct.held do claude_wait_dropped(h.id) // a wait naming it ends (claude_wait.odin)
			held_clear(ct)
			return {ok = true}, true
		case "send":
			if len(ct.held) == 0 do return fail("nothing waits"), false
			if tab.status != .Running do return fail("Claude is not running in this tab"), false
			// the user's call goes into whatever they typed, never into a dialog (its Enter would
			// pick the highlighted answer) nor before Claude is up
			// only at an idle turn (a permission dialog can be up before its hook says so): Send now
			// skips just the wait for what the user typed
			switch ct.turn {
			case .Idle:
			case .Working: return fail("Claude is busy: wait for its turn to end"), false
			case .Waiting, .Unknown:
				_, why := claude_ready(tab, ct)
				return fail(fmt.tprintf("%s: answer Claude first", why)), false
			}
			// and Claude's own OSC 7501 agrees: a dialog it reports before its Notification hook
			if v := tab_status_view(tab^); v.source == .Osc7501 {
				#partial switch v.state {
				case .Blocked: return fail("Claude is waiting for you: answer Claude first"), false
				case .Working: return fail("Claude is busy: wait for its turn to end"), false
				}
			}
			if why := claude_paste_refused(tab); why != "" do return fail(why), false
			return claude_apply(Claude_Deliver{tab_id = c.tab_id, force = true}, caller, request_id)
		}
		return fail("op must be send or drop"), false
	case Claude_Deliver:
		_, tab, ct := claude_tab_of(c.tab_id)
		if ct == nil || len(ct.held) == 0 do return {ok = true}, false
		if ok, why := claude_ready(tab, ct); !ok && !c.force do return fail(why), false
		if rt := claude_rt[tab.id]; rt.ro_need && !rt.ro_acked do return fail("Claude is starting (its read-only guard has not confirmed yet)"), false // even Send now
		if why := claude_paste_refused(tab); why != "" do return fail(why), false
		t := term_of(tab.id)
		if t == nil || !t.running do return fail("Claude is not running in this tab"), false
		h := ct.held[0]
		ordered_remove(&ct.held, 0)
		term_paste(t, h.text)
		delete(h.text)
		delete(h.who)
		ct.turn = .Working // until its hooks say otherwise: one text at a time
		rt := claude_rt[tab.id]
		rt.enter_due = time.tick_add(time.tick_now(), CLAUDE_ENTER_DELAY)
		rt.typed = false
		claude_rt[tab.id] = rt
		return {ok = true}, true
	case Claude_Readonly_Ack:
		_, tab, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		rt := claude_rt[tab.id]
		if tab.status != .Running || !ct.readonly || !rt.ro_need || ct.guard_stopped do return fail("this tab waits for no read-only ack"), false
		if rt.ro_acked do return fail("already acknowledged"), false
		if len(c.nonce) != len(rt.ro_nonce) || c.nonce != string(rt.ro_nonce[:]) do return fail("not this start's ack"), false
		rt.ro_acked = true
		claude_rt[tab.id] = rt
		return {ok = true}, true
	case Claude_Restore_History:
		// the saved list first (least recently used first), then the history's read-only records
		// it does not have (even ones dropped below) while there is room: never past the cap
		for id in c.readonly_ids do claude_readonly_mark(id)
		for r in c.records do if r.readonly && claude_id_ok(r.id) && !claude_readonly_listed(r.id) {
			if len(state.claude_readonly_ids) >= CLAUDE_READONLY_IDS_MAX do break
			append(&state.claude_readonly_ids, strings.clone(r.id))
		}
		for r in c.records {
			// as a report would be: an id that can go into argv, no flags pi-desk sets, an absolute
			// project, a one-line title of at most CLAUDE_TITLE_MAX
			if !claude_id_ok(r.id) || len(state.claude_history) >= CLAUDE_HISTORY_MAX do continue
			if claude_args_check(r.args) != "" || !strings.has_prefix(r.project, "/") do continue
			if old, _ := claude_record(r.id); old != nil do continue
			title := cut_utf8(strings.trim_space(one_line(r.title, context.temp_allocator)), CLAUDE_TITLE_MAX)
			// the transcript path and model as a report's would be (claude_rows.odin)
			// its account: an absolute folder, else "" (an older entry's): the default account as
			// resolved when it is used, never a folder stamped at load (from inside a Claude session
			// whose login shell did not answer, the environment's would be the parent session's)
			acct := filepath.is_abs(r.account) ? r.account : ""
			append(&state.claude_history, Claude_Record{id = strings.clone(r.id), cwd = strings.clone(r.cwd), project = strings.clone(r.project), title = strings.clone(title), used = r.used, args = clone_strings(r.args), named = r.named && title != "", transcript = strings.clone(claude_transcript_ok(r.transcript)), model = strings.clone(claude_model_clean(r.model)), readonly = r.readonly, account = strings.clone(acct)})
		}
		return {ok = true}, true
	}
	return fail("not a Claude command"), false
}

// The tab a claude.* report is about (caller_may: a Claude tab reports for itself only).
claude_command_tab :: proc(cmd: Command) -> u64 {
	#partial switch c in cmd {
	case Claude_Session_Report: return c.tab_id
	case Claude_Turn_Report:    return c.tab_id
	case Claude_Readonly_Ack:   return c.tab_id
	case Claude_Comments:       return c.tab_id
	case Claude_Attached:       return c.tab_id
	case Claude_Prompt:         return c.tab_id
	case Claude_Held_Op:        return c.tab_id
	case Claude_Deliver:        return c.tab_id
	case Claude_Model_Report:   return c.tab_id
	}
	return claude_extra_tab(cmd) // claude_panels.odin
}

// ---- wire ----

claude_command_type :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case New_Claude_Tab:         return "new_claude_tab"
	case New_Claude_Session:     return "new_claude_session"
	case Claude_Rename:          return "claude_rename"
	case Claude_Resume:          return "claude_resume"
	case Claude_Session_Report:  return "claude.session"
	case Claude_Turn_Report:     return "claude.turn"
	case Claude_Readonly_Ack:    return "claude.readonly_ack"
	case Claude_Comments:        return "claude.comments"
	case Claude_Attached:        return "claude.attached"
	case Claude_Prompt:          return "claude_prompt"
	case Claude_Held_Op:         return "claude_held"
	case Claude_Deliver:         return "claude_deliver"
	case Claude_Restore_History: return "claude_restore_history"
	}
	return ""
}

// The command's fields for events and the log: never prompt text, titles or flags' values.
claude_command_write :: proc(b: ^strings.Builder, cmd: Command, redact: bool) {
	#partial switch c in cmd {
	case New_Claude_Tab:
		if c.session != 0 do fmt.sbprintf(b, `,"session":%d`, c.session)
		if c.project_id != 0 do fmt.sbprintf(b, `,"project_id":%d`, c.project_id)
		if c.cwd != "" {
			strings.write_string(b, `,"cwd":`)
			json_quote(b, c.cwd)
		}
		if c.resume != "" {
			strings.write_string(b, `,"resume":`)
			json_quote(b, c.resume)
		}
		if len(c.args) > 0 do fmt.sbprintf(b, `,"argc":%d`, len(c.args))
		if c.account != "" {
			strings.write_string(b, `,"account":`)
			json_quote(b, c.account)
		}
	case New_Claude_Session:
		fmt.sbprintf(b, `,"project_id":%d`, c.project_id)
		if c.account != "" {
			strings.write_string(b, `,"account":`)
			json_quote(b, c.account)
		}
		if c.cwd != "" {
			strings.write_string(b, `,"cwd":`)
			json_quote(b, c.cwd)
		}
		if len(c.args) > 0 do fmt.sbprintf(b, `,"argc":%d`, len(c.args))
	case Claude_Rename:
		strings.write_string(b, `,"claude_session_id":`)
		json_quote(b, c.claude_session_id)
		fmt.sbprintf(b, `,"title":"<redacted %d bytes>"`, len(c.title))
	case Claude_Resume:
		strings.write_string(b, `,"claude_session_id":`)
		json_quote(b, c.claude_session_id)
	case Claude_Session_Report:
		fmt.sbprintf(b, `,"tab_id":%d,"session_id":`, c.tab_id)
		json_quote(b, c.session_id)
		if c.source != "" {
			strings.write_string(b, `,"source":`)
			json_quote(b, c.source)
		}
		if c.model != "" {
			strings.write_string(b, `,"model":`)
			json_quote(b, c.model)
		}
		if c.transcript_path != "" do strings.write_string(b, `,"transcript_path":"<path>"`)
	case Claude_Turn_Report:
		fmt.sbprintf(b, `,"tab_id":%d,"state":`, c.tab_id)
		json_quote(b, c.state)
		if c.title != "" do fmt.sbprintf(b, `,"title":"<redacted %d bytes>"`, len(c.title))
		if c.question do strings.write_string(b, `,"question":true`)
		if c.idle_prompt do strings.write_string(b, `,"idle_prompt":true`)
	case Claude_Comments:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		if c.max != 0 do fmt.sbprintf(b, `,"max":%d`, c.max)
	case Claude_Attached:
		fmt.sbprintf(b, `,"tab_id":%d,"attachment_id":%d`, c.tab_id, c.attachment_id)
	case Claude_Prompt:
		fmt.sbprintf(b, `,"tab_id":%d,"text":`, c.tab_id)
		if redact do fmt.sbprintf(b, `"<redacted %d bytes>"`, len(c.text))
		else do json_quote(b, c.text)
	case Claude_Held_Op:
		fmt.sbprintf(b, `,"tab_id":%d,"op":`, c.tab_id)
		json_quote(b, c.op)
	case Claude_Deliver:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		if c.force do strings.write_string(b, `,"force":true`)
	case Claude_Restore_History:
		fmt.sbprintf(b, `,"records":%d`, len(c.records))
	case Claude_Readonly_Ack:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id) // never the nonce
	}
}

claude_command_clone :: proc(cmd: Command, allocator := context.allocator) -> Command {
	s :: proc(v: string, a := context.allocator) -> string {return strings.clone(v, a)}
	ss :: proc(v: []string, a := context.allocator) -> []string {
		out := make([]string, len(v), a)
		for x, i in v do out[i] = strings.clone(x, a)
		return out
	}
	#partial switch c in cmd {
	case New_Claude_Tab:        return New_Claude_Tab{session = c.session, project_id = c.project_id, cwd = s(c.cwd, allocator), resume = s(c.resume, allocator), args = ss(c.args, allocator), account = s(c.account, allocator)}
	case New_Claude_Session:    return New_Claude_Session{project_id = c.project_id, cwd = s(c.cwd, allocator), args = ss(c.args, allocator), account = s(c.account, allocator)}
	case Claude_Rename:         return Claude_Rename{claude_session_id = s(c.claude_session_id, allocator), title = s(c.title, allocator)}
	case Claude_Resume:         return Claude_Resume{claude_session_id = s(c.claude_session_id, allocator)}
	case Claude_Session_Report: return Claude_Session_Report{tab_id = c.tab_id, session_id = s(c.session_id, allocator), cwd = s(c.cwd, allocator), source = s(c.source, allocator), transcript_path = s(c.transcript_path, allocator), model = s(c.model, allocator)}
	case Claude_Turn_Report:    return Claude_Turn_Report{tab_id = c.tab_id, state = s(c.state, allocator), title = s(c.title, allocator), question = c.question, idle_prompt = c.idle_prompt}
	case Claude_Prompt:         return Claude_Prompt{tab_id = c.tab_id, text = s(c.text, allocator)}
	case Claude_Held_Op:        return Claude_Held_Op{tab_id = c.tab_id, op = s(c.op, allocator)}
	case Claude_Restore_History:
		out := make([]Claude_Record, len(c.records), allocator)
		for r, i in c.records do out[i] = {id = s(r.id, allocator), cwd = s(r.cwd, allocator), project = s(r.project, allocator), title = s(r.title, allocator), used = r.used, args = ss(r.args, allocator), named = r.named, transcript = s(r.transcript, allocator), model = s(r.model, allocator), readonly = r.readonly, account = s(r.account, allocator)}
		return Claude_Restore_History{records = out, readonly_ids = ss(c.readonly_ids, allocator)}
	case Claude_Readonly_Ack: return Claude_Readonly_Ack{tab_id = c.tab_id, nonce = s(c.nonce, allocator)}
	}
	return cmd
}

claude_command_free :: proc(cmd: Command, allocator := context.allocator) {
	ss :: proc(v: []string, a := context.allocator) {
		for x in v do delete(x, a)
		delete(v, a)
	}
	#partial switch c in cmd {
	case New_Claude_Tab:
		delete(c.cwd, allocator)
		delete(c.resume, allocator)
		delete(c.account, allocator)
		ss(c.args, allocator)
	case New_Claude_Session:
		delete(c.cwd, allocator)
		delete(c.account, allocator)
		ss(c.args, allocator)
	case Claude_Rename:
		delete(c.claude_session_id, allocator)
		delete(c.title, allocator)
	case Claude_Resume: delete(c.claude_session_id, allocator)
	case Claude_Session_Report:
		delete(c.session_id, allocator)
		delete(c.cwd, allocator)
		delete(c.source, allocator)
		delete(c.transcript_path, allocator)
		delete(c.model, allocator)
	case Claude_Turn_Report:
		delete(c.state, allocator)
		delete(c.title, allocator)
	case Claude_Readonly_Ack: delete(c.nonce, allocator)
	case Claude_Prompt:  delete(c.text, allocator)
	case Claude_Held_Op: delete(c.op, allocator)
	case Claude_Restore_History:
		for r in c.records {
			delete(r.id, allocator)
			delete(r.cwd, allocator)
			delete(r.project, allocator)
			delete(r.title, allocator)
			ss(r.args, allocator)
			delete(r.transcript, allocator)
			delete(r.model, allocator)
			delete(r.account, allocator)
		}
		ss(c.readonly_ids, allocator)
		delete(c.records, allocator)
	}
}

// A Claude tab's entry in the snapshot (json_write.odin): its session id, turn, held texts'
// count and who sent them (never their text), its extra flags' count, and why held texts wait.
claude_tab_json :: proc(b: ^strings.Builder, tab: Tab) {
	ct, is := tab.kind.(Claude_Tab)
	if !is do return
	strings.write_string(b, `,"claude_session_id":`)
	json_quote(b, ct.session_id)
	fmt.sbprintf(b, `,"turn":"%s","held":%d,"typed":%v,"argc":%d`, CLAUDE_TURN_NAMES[ct.turn], len(ct.held), claude_typed(tab.id), len(ct.args))
	if ct.readonly do strings.write_string(b, `,"readonly":true`)
	if tag := claude_account_tag(ct.account); tag != "" {
		strings.write_string(b, `,"account":`)
		json_quote(b, tag)
	}
	claude_rows_tab_json(b, ct)
	claude_status_tab_json(b, tab) // background work, silent hooks, an old Claude Code (claude_status.odin)
	if len(ct.held) > 0 {
		tab := tab
		_, why := claude_ready(&tab, &ct)
		strings.write_string(b, `,"held_wait":`)
		json_quote(b, why)
	}
}

// The history in the snapshot (titles are the user's own first prompts).
claude_history_json :: proc(b: ^strings.Builder, list: []Claude_Record, found, found_chats: []Claude_Disk) {
	strings.write_string(b, `,"claude_sessions":[`)
	for r, i in list {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, `{"id":`)
		json_quote(b, r.id)
		strings.write_string(b, `,"cwd":`)
		json_quote(b, r.cwd)
		strings.write_string(b, `,"project":`)
		json_quote(b, r.project)
		strings.write_string(b, `,"title":`)
		json_quote(b, r.title)
		if r.model != "" {
			strings.write_string(b, `,"model":`)
			json_quote(b, r.model)
		}
		fmt.sbprintf(b, `,"used":%d,"open":%v`, r.used, claude_open_tab(r.id) != 0)
		if r.readonly do strings.write_string(b, `,"readonly":true`)
		if tag := claude_account_tag(r.account); tag != "" {
			strings.write_string(b, `,"account":`)
			json_quote(b, tag)
		}
		if f := claude_disk_of(r.id); f != nil {
			if f.gone do strings.write_string(b, `,"gone":true`)
			if f.created != {} do fmt.sbprintf(b, `,"created":%d`, time.to_unix_seconds(f.created))
		}
		strings.write_byte(b, '}')
	}
	// the transcripts found on disk for the selected project and Chats (claude_disk.odin): rows
	// as pi's are, never a path
	first := len(list) == 0
	claude_disk_json(b, find_project(state.selected_project), found, &first)
	claude_disk_json(b, chats_project(), found_chats, &first)
	strings.write_byte(b, ']')
}
