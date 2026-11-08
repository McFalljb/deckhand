package main

// A session's info for Atlas (and the user): "Copy session info" and "Send
// to Atlas" on a session row's right-click menu and its ⓘ button, and the
// `session_info` command. Read from the session file's header (its first
// line) and the file's metadata only, plus the title cache: never the
// conversation. The text is a fenced block of `key: value` lines, so a
// person reads it and Atlas can look the session up itself:
//
//   ```pi-session
//   id: 0193…
//   file: /Users/me/.pi/agent/sessions/--Users-me-code-api--/2026-…_0193….jsonl
//   project: api
//   folder: /Users/me/code/api
//   title: Fix the flaky test
//   created: 2026-10-30T10:00:00.000Z
//   modified: 2026-11-01T12:00:03Z
//   model: anthropic/claude-sonnet-4-5
//   ```
//
// Lines without a value are left out (model: only when the header has it).
//
// Send to Atlas puts the block into Atlas's input (its pi editor) without
// sending it: the drawer opens with the keyboard there, so the user adds
// a question and presses Enter. Nothing is asked of Atlas and no model call
// is made until they do. AGENT_SEND_SUBMITS = true sends it at once instead
// (pi_prompt to Atlas's tab, through its bridge).

import "core:encoding/json"
import jg "jsonguard"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// false: prefill Atlas's input (the user sends it); true: send it as a prompt now.
AGENT_SEND_SUBMITS :: false

SESSION_HEADER_MAX :: 64 * 1024 // the header line is read up to this

// Shows a session's info: data only (to = ""), also copied (clipboard), or
// put into Atlas's input (agent: the user's only).
Session_Info :: struct {
	project_id:    u64,
	pi_session_id: string,
	to:            string, // "" | "clipboard" | "agent"
}

// What the info says (temp allocator).
Session_Facts :: struct {
	id:       string,
	file:     string,
	project:  string,
	cwd:      string,
	title:    string,
	created:  string,
	modified: string,
	model:    string,
	agent:    string, // "Claude Code" for a Claude row ("" = pi)
	used:     string, // a Claude row: its last use (pi-desk's history)
}

// The facts in a session file: its header line and its metadata. The
// project and title come from the caller (the sidebar, the title cache).
session_facts_read :: proc(path: string) -> (f: Session_Facts, err: string) {
	context.allocator = context.temp_allocator
	fh, oerr := os.open(path)
	if oerr != nil do return f, "the session file cannot be read"
	defer os.close(fh)
	info, serr := os.fstat(fh, context.temp_allocator)
	if serr != nil do return f, "the session file cannot be read"
	if info.type != .Regular do return f, "not a session file"
	buf := make([]u8, min(max(info.size, 0), SESSION_HEADER_MAX))
	n, _ := os.read_at(fh, buf, 0)
	head := string(buf[:max(n, 0)])
	if nl := strings.index_byte(head, '\n'); nl >= 0 do head = head[:nl]
	else if i64(n) < info.size do return f, "the session header is too long"
	v, perr := jg.parse_string(strings.trim_right(head, "\r"), .JSON, true)
	obj, is_obj := v.(json.Object)
	if perr != nil || !is_obj do return f, "the session file has no header"
	str :: proc(o: json.Object, k: string) -> string {
		s, _ := o[k].(json.String)
		return one_line(string(s))
	}
	if str(obj, "type") != "session" do return f, "the session file has no header"
	f.file = path
	f.id = str(obj, "id")
	if f.id == "" do f.id = session_id_from_name(filepath.base(path))
	f.cwd = str(obj, "cwd")
	f.created = str(obj, "timestamp")
	if f.created == "" do f.created = stamp_iso(filepath.base(path))
	if f.created == "" && info.creation_time != {} do f.created = time_iso(info.creation_time)
	if info.modification_time != {} do f.modified = time_iso(info.modification_time)
	f.model = str(obj, "model")
	if f.model == "" {
		if id := str(obj, "modelId"); id != "" {
			p := str(obj, "provider")
			f.model = p != "" ? fmt.tprintf("%s/%s", p, id) : id
		}
	}
	return f, ""
}

// "2026-10-30T10-00-00-000Z_<id>.jsonl" → "2026-10-30T10:00:00Z", "" if not one.
@(private = "file")
stamp_iso :: proc(name: string) -> string {
	if len(name) < 19 || name[10] != 'T' || name[13] != '-' || name[16] != '-' do return ""
	for i in ([]int{0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18}) do if name[i] < '0' || name[i] > '9' do return ""
	return fmt.tprintf("%s:%s:%sZ", name[:13], name[14:16], name[17:19])
}

@(private = "file")
time_iso :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

// The block (temp allocator): ```pi-session, key: value lines, ```. Values
// are one line each; the fence is longer than any run of backticks in them.
session_info_text :: proc(f: Session_Facts) -> string {
	b := strings.builder_make(context.temp_allocator)
	pairs := [?][2]string{{"id", f.id}, {"agent", f.agent}, {"file", f.file}, {"project", f.project}, {"folder", f.cwd}, {"title", redact_secrets(f.title)}, {"created", f.created}, {"modified", f.modified}, {"used", f.used}, {"model", f.model}}
	run := 0
	for p in pairs {
		n := 0
		for c in transmute([]u8)p[1] {
			n = c == '`' ? n + 1 : 0
			run = max(run, n)
		}
	}
	fence := strings.repeat("`", max(3, run + 1), context.temp_allocator)
	fmt.sbprintf(&b, "%s%s\n", fence, f.agent != "" ? "claude-session" : "pi-session")
	for p in pairs {
		v := strings.trim_space(one_line(p[1], context.temp_allocator))
		if v == "" do continue
		fmt.sbprintf(&b, "%s: %s\n", p[0], v)
	}
	strings.write_string(&b, fence)
	return strings.to_string(b)
}

// A listed session's facts and its block (temp allocator); err: why not.
session_info_build :: proc(project_id: u64, pi_session_id: string) -> (f: Session_Facts, text: string, err: string) {
	if pi_session_id == "" do return f, "", "pi_session_id is empty"
	if rec := claude_row_record(project_id, pi_session_id); rec != nil do return claude_facts(project_id, rec)
	path, perr := sidebar_path(project_id, pi_session_id)
	if perr != "" do return f, "", perr
	ferr: string
	f, ferr = session_facts_read(path)
	if ferr != "" do return f, "", ferr
	if p := find_project(project_id); p != nil do f.project = p.group == .Chats ? "Chats" : project_display(p^)
	// the title: the title cache's, else the listing's (never read here)
	f.title = title_cached(path, context.temp_allocator)
	if f.title == "" {
		for s in state.sessions do if s.id == pi_session_id do f.title = s.title
		for s in state.chats do if s.id == pi_session_id do f.title = s.title
	}
	f.title = cut_utf8(one_line(f.title, context.temp_allocator), 200)
	return f, session_info_text(f), ""
}

// A Claude row's facts: pi-desk's own history entry (never Claude Code's files), its transcript
// path only while it is still one under Claude's projects/ (claude_rows.odin).
@(private = "file")
claude_facts :: proc(project_id: u64, rec: ^Claude_Record) -> (f: Session_Facts, text: string, err: string) {
	f.id = strings.clone(rec.id, context.temp_allocator)
	f.agent = "Claude Code"
	f.file, _ = claude_transcript_file(rec)
	if p := find_project(project_id); p != nil do f.project = project_display(p^)
	f.cwd = strings.clone(rec.cwd, context.temp_allocator)
	f.title = cut_utf8(one_line(rec.title, context.temp_allocator), 200)
	if rec.used > 0 do f.used = time_iso(time.unix(rec.used, 0))
	f.model = strings.clone(rec.model, context.temp_allocator)
	return f, session_info_text(f), ""
}

// The session_info command (commands.odin).
session_info_apply :: proc(c: Session_Info, caller: Caller) -> (Result, bool) {
	switch c.to {
	case "", "clipboard", "agent":
	case: return fail(`to: "", "clipboard" or "agent"`), false
	}
	if c.to == "agent" && caller.kind != .UI && caller.kind != .Internal do return fail("only the user sends to the agent"), false
	f, text, err := session_info_build(c.project_id, c.pi_session_id)
	if err != "" do return fail(err), false
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"text":`)
	json_quote(&b, text)
	for kv in ([?][2]string{{"id", f.id}, {"file", f.file}, {"project", f.project}, {"cwd", f.cwd}, {"title", redact_secrets(f.title)}, {"created", f.created}, {"modified", f.modified}, {"model", f.model}, {"agent", f.agent}, {"used", f.used}}) {
		if (kv[0] == "agent" || kv[0] == "used") && kv[1] == "" do continue // pi's answer as before
		fmt.sbprintf(&b, `,"%s":`, kv[0])
		json_quote(&b, kv[1])
	}
	strings.write_byte(&b, '}')
	r := Result{ok = true, data = strings.to_string(b)}
	switch c.to {
	case "clipboard":
		if platform.set_clipboard != nil do platform.set_clipboard(text)
	case "agent":
		if sr := agent_send(fmt.tprintf("%s\n", text), caller); !sr.ok {
			sr.data = r.data
			return sr, true
		}
		return r, true // the drawer opened
	}
	return r, false
}

// ---- Atlas's input ----

// Text waiting for Atlas's pi to come up (its first status), then pasted.
@(private = "file")
agent_pending: struct {
	tab:      u64,
	text:     string, // owned
	deadline: time.Tick,
	ready:    bool, // pi reported; its editor's bracketed paste is not on yet (the pty is behind the socket)
}

// After pi's first status, how long its terminal may take to turn bracketed
// paste on (its output and its bridge's status come by different ways).
PASTE_WAIT :: 2 * time.Second

// Opens the drawer (keyboard in Atlas's terminal) and puts text into
// Atlas's input: pasted, not sent (AGENT_SEND_SUBMITS sends it). While
// Atlas's pi is starting it waits for pi's first status (PICKER_WAIT).
agent_send :: proc(text: string, caller: Caller) -> Result {
	r := run_command(Set_Home{open = true}, caller)
	ht := home_tab()
	if ht == nil || ht.status != .Running do return agent_send_failed(text, r.ok ? fmt.tprintf("%s's pi is not running", agent_name()) : r.error)
	if ht.waiting do return agent_send_failed(text, fmt.tprintf("%s is waiting for you", agent_name()))
	if ht.agent == .Unknown && time.tick_since(agent_started) < PICKER_WAIT {
		if agent_pending.tab != 0 do agent_send_failed(agent_pending.text, "sent again before it went in")
		delete(agent_pending.text)
		agent_pending = {tab = ht.id, text = strings.clone(text), deadline = time.tick_add(agent_started, PICKER_WAIT)}
		return {ok = true}
	}
	// pi reported, but its terminal has not turned paste mode on yet (just
	// started: the status beat the pty output): wait for it as a pending one does
	if t := term_of(ht.id); !AGENT_SEND_SUBMITS && t != nil && t.running && !mode_on(t, 2004) && time.tick_since(agent_started) < PICKER_WAIT {
		deadline := time.tick_add(time.tick_now(), PASTE_WAIT)
		if agent_pending.tab != 0 {
			if agent_pending.ready && agent_pending.tab == ht.id do deadline = agent_pending.deadline // the wait already running
			agent_send_failed(agent_pending.text, "sent again before it went in")
		}
		delete(agent_pending.text)
		agent_pending = {tab = ht.id, text = strings.clone(text), deadline = deadline, ready = true}
		return {ok = true}
	}
	if err := agent_deliver(ht.id, text); err != "" do return agent_send_failed(text, err)
	return {ok = true}
}

// Text that could not go into Atlas's input: kept on the clipboard and said
// in the bell (the user may not be looking at the drawer: it waited for pi).
@(private = "file")
agent_send_failed :: proc(text, why: string) -> Result {
	if platform.set_clipboard != nil do platform.set_clipboard(text)
	notify_failed(fmt.tprintf("Send to %s", agent_name()), fmt.tprintf("%s: copied to the clipboard", why))
	// also on screen now: it may have waited for pi, after the menu's own outcome
	window_toast(fmt.tprintf("Send to %s: %s: copied to the clipboard", agent_name(), why), err = true)
	return fail(fmt.tprintf("%s: copied to the clipboard", why))
}

// "" when the text went in, else why not.
@(private = "file")
agent_deliver :: proc(tab: u64, text: string) -> string {
	if AGENT_SEND_SUBMITS {
		ui_do(Pi_Prompt{tab_id = tab, text = strings.trim_right(text, "\n")})
		return ""
	}
	t := term_of(tab)
	if t == nil || !t.running do return fmt.tprintf("%s's pi is not running", agent_name())
	// without bracketed paste a newline would send the first line
	if !mode_on(t, 2004) do return fmt.tprintf("%s's input does not take pasted text now", agent_name())
	term_paste(t, text)
	return ""
}

// Text waiting for a pi tab that exited or was stopped: said now (and on
// the clipboard), never kept for the next pi.
agent_pending_drop :: proc(tab: u64) {
	if agent_pending.tab == 0 || agent_pending.tab != tab do return
	text := agent_pending.text
	agent_pending = {}
	defer delete(text)
	agent_send_failed(text, fmt.tprintf("%s's pi exited", agent_name()))
}

// The frame's tick: text that waited past its deadline is said now, so a
// late status can never put it on the clipboard afterwards.
agent_pending_tick :: proc(now := time.Tick{}) {
	if agent_pending.tab == 0 do return
	n := now == {} ? time.tick_now() : now
	if agent_pending.ready {
		// pi reported: in as soon as its terminal takes a paste
		t := term_of(agent_pending.tab)
		if t != nil && t.running && mode_on(t, 2004) {
			tab, text := agent_pending.tab, agent_pending.text
			agent_pending = {}
			defer delete(text)
			if err := agent_deliver(tab, text); err != "" do agent_send_failed(text, err)
			return
		}
		if time.tick_diff(n, agent_pending.deadline) > 0 do return
		text := agent_pending.text
		agent_pending = {}
		defer delete(text)
		agent_send_failed(text, fmt.tprintf("%s's input does not take pasted text now", agent_name()))
		return
	}
	if time.tick_diff(n, agent_pending.deadline) > 0 do return
	text := agent_pending.text
	agent_pending = {}
	defer delete(text)
	agent_send_failed(text, fmt.tprintf("%s's pi took too long to start", agent_name()))
}

// Atlas's pi reported its status (commands.odin, Pi_Status_Update): text
// waiting for it goes in now, unless a dialog is open, the model selector
// opened at this status (picker), pi started over, or it waited too long;
// then it is said why.
agent_pending_status :: proc(tab: u64, waiting, picker: bool) {
	if agent_pending.tab == 0 do return
	text := agent_pending.text
	defer delete(text)
	same := agent_pending.tab == tab
	in_time := time.tick_diff(time.tick_now(), agent_pending.deadline) > 0
	// already waiting for the paste mode: a later status keeps that deadline
	paste_deadline := same && agent_pending.ready ? agent_pending.deadline : time.tick_add(time.tick_now(), PASTE_WAIT)
	agent_pending = {}
	switch {
	case !same:   agent_send_failed(text, fmt.tprintf("%s's pi started over", agent_name()))
	case !in_time: agent_send_failed(text, fmt.tprintf("%s's pi took too long to start", agent_name()))
	case waiting: agent_send_failed(text, fmt.tprintf("%s is waiting for you", agent_name()))
	case picker:  agent_send_failed(text, "the model selector opened")
	case:
		// the status can come before pi's terminal output that turns bracketed
		// paste on: wait for it a little (agent_pending_tick)
		if t := term_of(tab); !AGENT_SEND_SUBMITS && t != nil && t.running && !mode_on(t, 2004) {
			agent_pending = {tab = tab, text = strings.clone(text), deadline = paste_deadline, ready = true}
			return
		}
		if err := agent_deliver(tab, text); err != "" do agent_send_failed(text, err)
	}
}
