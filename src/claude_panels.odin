package main

// Claude tabs, part two (docs/CLAUDE.md §6a, §6b, §9): Claude's todos, subagents and background
// work as right-column panels, and claude_restart (a dead Claude tab's Restart, dead_tab.odin).
//
// The plugin's async hooks (integrations/claude-code/hooks/hooks.json, tools/pi-desk-cli/
// hooks.odin) report what Claude Code tells them, for the token's own tab only (caller_may,
// claude_command_tab):
//   - claude.todos: the whole list from TodoWrite (PostToolUse);
//   - claude.task: one task of the Task tools (TaskCreated, PostToolUse TaskUpdate,
//     TaskCompleted), by its id;
//   - claude.subagent: launch (PreToolUse on the Agent tool: its type and description), start and
//     stop (SubagentStart, SubagentStop: the agent's id and type), tool (PreToolUse inside a
//     subagent: its current tool; pi-desk counts the steps and times start to stop). A launch and
//     a start are paired by type, in whichever order they arrive. A TodoWrite inside a subagent
//     (claude.todos with agent_id) is that subagent's own list, shown under it;
//   - claude.background (§6b): launch (PostToolUse on a background Bash: its task id) and snapshot
//     (Stop, SubagentStop: background_tasks and session_crons, what still runs at a turn's end).
//     It blocks nothing (as pi's blockers, which feed only pi's reload confirmation): the restart
//     confirmation names it (claude_reload.odin), a claude_wait_idle result lists it
//     (claude_wait.odin); the dot never changes for it (claude_status.odin). Only a snapshot's
//     running tasks are counted; a launch no Stop confirms ends at the next Stop without one. Display only: pi-desk cannot stop Claude's
//     background tasks (no documented way from outside), and the panel says so.
// The text is Claude's and untrusted: pi-desk keeps it bounded (counts and bytes), one line,
// without control, bidi or invisible characters, and builds the panel rows itself (a Claude tab
// never sends rows, tones or panel ids). The panels live on the Claude tab (Tab.panels), never on
// pi's tab, and pi's bridge cannot set them (panel.set is pi tabs' only). They show in the right
// column while that Claude tab is the active tab (right_panels_tab). Hooks run async, so reports
// can arrive out of order: a report carries `seq` (the hook process's start, monotonic ns) and an
// older one never overwrites a newer one. Not saved: a new process (claude_start), a new
// conversation (claude.session but after a compaction) and an exit clear them.

import "core:fmt"
import "core:strings"
import "core:time"

// ---- commands (rows in command_table.odin) ----

Claude_Todo_In :: struct {
	content:     string,
	status:      string, // pending | in_progress | completed (anything else: pending)
	active_form: string,
}
// TodoWrite's whole list.
Claude_Todos :: struct {
	tab_id:   u64,
	todos:    []Claude_Todo_In, // at most CLAUDE_TODOS_IN_MAX (json_read)
	agent_id: string, // inside a subagent: that subagent's own list ("" = the main conversation's)
	seq:      u64,
}
// One task of the Task tools.
Claude_Task :: struct {
	tab_id:      u64,
	event:       string, // created | updated | completed
	task_id:     string,
	subject:     string,
	active_form: string,
	status:      string, // updated: pending | in_progress | completed | deleted
	seq:         u64,
}
Claude_Subagent :: struct {
	tab_id:      u64,
	event:       string, // launch | start | stop | tool
	agent_id:    string, // start, stop, tool
	agent_type:  string,
	description: string, // launch
	tool_name:   string, // tool: the tool it calls now
	seq:         u64,
}
// One task of a Stop's background_tasks.
Claude_Bg_In :: struct {
	id, kind, status, description, command: string,
}
// One of a Stop's session_crons.
Claude_Cron_In :: struct {
	id, schedule, prompt: string,
	recurring:            bool,
}
// Claude's background work: a launch (one task) or a Stop's snapshot (all of them).
Claude_Background :: struct {
	tab_id:      u64,
	event:       string, // launch | snapshot
	task_id:     string, // launch
	kind:        string, // launch: shell
	description: string, // launch
	command:     string, // launch
	tasks:       []Claude_Bg_In, // snapshot: at most CLAUDE_BG_IN_MAX (json_read)
	crons:       []Claude_Cron_In, // snapshot: at most CLAUDE_CRONS_IN_MAX
	seq:         u64,
}
// A dead Claude tab's Restart (dead_tab.odin, claude_tab_restart).
Claude_Restart :: struct {
	tab_id:     u64,
	pick_model: bool, // Restart with model…: /model once the new Claude is ready (dead_tab.odin)
}

CLAUDE_TODOS_MAX :: 50 // kept per tab; a longer TodoWrite list shows "+N more"
CLAUDE_TODOS_IN_MAX :: 100 // a claude.todos list longer than this is refused
CLAUDE_AGENTS_MAX :: 16 // subagents kept per tab (finished ones go first)
CLAUDE_LAUNCHES_MAX :: 8 // Agent tool calls waiting for their SubagentStart
CLAUDE_ITEM_TEXT_MAX :: 140 // bytes of a todo's or subagent's text
CLAUDE_KIND_MAX :: 64 // bytes of a subagent's type
CLAUDE_KEY_MAX :: 64 // bytes of a task or agent id
CLAUDE_AGENT_TODOS_MAX :: 20 // a subagent's own todos kept (more: counted)
CLAUDE_AGENT_TODOS_SHOWN :: 8 // shown under a running subagent
CLAUDE_BG_MAX :: 16 // background tasks kept per tab (finished ones go first)
CLAUDE_BG_IN_MAX :: 64 // a snapshot with more tasks is refused
CLAUDE_CRONS_MAX :: 8 // session crons kept
CLAUDE_CRONS_IN_MAX :: 32 // a snapshot with more crons is refused
CLAUDE_PANELS_EVERY :: time.Second // running subagents' times redrawn
CLAUDE_AGENT_STALE :: 2 * time.Hour // a running subagent silent this long (its SubagentStop lost?): its time no longer redrawn

// ---- runtime (not State, not saved) ----

@(private = "file")
Todo_State :: enum u8 {
	Pending,
	In_Progress,
	Completed,
	Deleted,
}

@(private = "file")
Todo :: struct {
	key:    string, // a task's id ("" in a TodoWrite list)
	text:   string,
	active: string, // its activeForm (shown while in progress)
	state:  Todo_State,
	seq:    u64,
}

@(private = "file")
Agent :: struct {
	id:        string,
	kind:      string,
	desc:      string,
	done:      bool,
	started:   time.Tick, // when pi-desk heard of it (its start, or a stop before it)
	last:      time.Tick, // its last report (start, tool, todos): a run with none for CLAUDE_AGENT_STALE stops being redrawn
	ended:     time.Tick, // its stop
	tool:      string, // its current tool (PreToolUse inside it)
	tool_seq:  u64,
	tools:     int, // tool calls seen
	todos:     [dynamic]Todo, // its own TodoWrite list
	todo_more: int,
	todo_seq:  u64,
}

// A background task: from its launch (PostToolUse on Bash) or a Stop's snapshot.
@(private = "file")
Bg :: struct {
	id, kind, desc, cmd: string,
	running:             bool,
	launch:              bool, // from a launch not yet in a snapshot: shown, never counted
	seq:                 u64, // its launch's (a newer snapshot without it: finished)
}

@(private = "file")
Cron :: struct {
	id, schedule, prompt: string,
	recurring:            bool,
}

@(private = "file")
Launch :: struct {
	kind, desc: string,
}

@(private = "file")
Work :: struct {
	todos:    [dynamic]Todo,
	more:     int, // TodoWrite items past CLAUDE_TODOS_MAX
	list_seq: u64, // the newest claude.todos applied
	agents:   [dynamic]Agent,
	launches: [dynamic]Launch,
	bg:       [dynamic]Bg,
	crons:    [dynamic]Cron,
	bg_seq:   u64, // the newest snapshot applied
	bg_snap:  bool, // a snapshot came (the panel says "as of Claude's last turn")
	snap_turn: bool, // a snapshot came since the last Stop's idle
	bg_more:  int, // running tasks past CLAUDE_BG_MAX (counted, not kept)
	drawn:    time.Tick, // the last render (running subagents' times)
}

@(private = "file")
claude_work: map[u64]Work

@(private = "file")
todo_free :: proc(t: Todo) {
	delete(t.key)
	delete(t.text)
	delete(t.active)
}

@(private = "file")
todos_clear :: proc(w: ^Work) {
	for t in w.todos do todo_free(t)
	clear(&w.todos)
	w.more = 0
}

@(private = "file")
agent_free :: proc(a: Agent) {
	delete(a.id)
	delete(a.kind)
	delete(a.desc)
	delete(a.tool)
	for t in a.todos do todo_free(t)
	delete(a.todos)
}

@(private = "file")
bg_free :: proc(b: Bg) {
	delete(b.id)
	delete(b.kind)
	delete(b.desc)
	delete(b.cmd)
}

@(private = "file")
crons_clear :: proc(w: ^Work) {
	for c in w.crons {
		delete(c.id)
		delete(c.schedule)
		delete(c.prompt)
	}
	clear(&w.crons)
}

// A tab's todos, subagents and background work go (a new process, a new conversation, its exit
// or close).
claude_work_reset :: proc(tab_id: u64) {
	w, has := &claude_work[tab_id]
	if !has do return
	todos_clear(w)
	delete(w.todos)
	for a in w.agents do agent_free(a)
	delete(w.agents)
	for b in w.bg do bg_free(b)
	delete(w.bg)
	crons_clear(w)
	delete(w.crons)
	for l in w.launches {
		delete(l.kind)
		delete(l.desc)
	}
	delete(w.launches)
	delete_key(&claude_work, tab_id)
}

@(private = "file")
work_of :: proc(tab_id: u64) -> ^Work {
	if tab_id not_in claude_work do claude_work[tab_id] = {}
	w, _ := &claude_work[tab_id]
	return w
}

// How many of a Claude tab's subagents run now (a restart waits for them: claude_reload.odin).
claude_subagents_running :: proc(tab_id: u64) -> int {
	w, has := claude_work[tab_id]
	if !has do return 0
	n := 0
	for a in w.agents do if !a.done do n += 1
	return n
}

// Whether a background task's status says it runs: only the ones known to (Claude Code's docs
// name no list); an unknown status is taken as over, so it never holds anything.
@(private = "file")
bg_running_status :: proc(status: string) -> bool {
	switch status {
	case "running", "pending", "in_progress", "queued", "starting":
		return true
	}
	return false
}

// How much of a Claude tab's background work runs, as Claude's last Stop reported it (a launch
// alone is not counted: an older Claude Code never reports its end): running tasks (shells,
// monitors, background subagents, workflows…) and one-shot wakeups (a recurring cron never ends).
// Only the restart confirmation and the snapshot's count use it; nothing waits for it.
claude_background_running :: proc(tab_id: u64) -> int {
	w, has := claude_work[tab_id]
	if !has do return 0
	n := w.bg_more
	for b in w.bg do if b.running && !b.launch do n += 1
	for c in w.crons do if !c.recurring do n += 1
	return n
}

// A task's name outside its panel (a wait's result, the restart confirmation, the tooltip): its
// description, else "<kind> #<id>"; never its command (those go to agents and the command log).
@(private = "file")
bg_name :: proc(b: Bg) -> string {
	if b.desc != "" do return cut_utf8(b.desc, 60)
	return fmt.tprintf("%s #%s", b.kind, b.id)
}

Claude_Bg_Item :: struct {
	kind, label: string,
}

// What runs, as claude_background_running counts it (temp; labels: bg_name).
claude_background_items :: proc(tab_id: u64) -> []Claude_Bg_Item {
	out := make([dynamic]Claude_Bg_Item, context.temp_allocator)
	w, has := claude_work[tab_id]
	if !has do return out[:]
	for b in w.bg do if b.running && !b.launch do append(&out, Claude_Bg_Item{b.kind, bg_name(b)})
	for c in w.crons do if !c.recurring do append(&out, Claude_Bg_Item{"wakeup", fmt.tprintf("at %s", c.schedule)})
	return out[:]
}

// The same, named for the restart confirmation (temp): "shell Start the dev server; monitor
// watch CI; +2 more"; "" = nothing.
claude_background_names :: proc(tab_id: u64, max_items := 3) -> string {
	items := claude_background_items(tab_id)
	w := claude_work[tab_id]
	parts := make([dynamic]string, context.temp_allocator)
	for x, i in items do if i < max_items do append(&parts, strings.has_prefix(x.label, fmt.tprintf("%s #", x.kind)) ? x.label : fmt.tprintf("%s %s", x.kind, x.label))
	if more := len(items) - len(parts) + w.bg_more; more > 0 do append(&parts, fmt.tprintf("+%d more", more))
	return strings.join(parts[:], "; ", context.temp_allocator)
}

// claude_wait_idle's result: what still runs ({"background":[{kind,label}],"background_count":n}),
// "" when nothing does.
claude_background_result :: proc(tab_id: u64) -> string {
	n := claude_background_running(tab_id)
	if n == 0 do return ""
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"background":[`)
	for x, i in claude_background_items(tab_id) {
		if i >= 8 do break
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"kind":`)
		json_quote(&b, x.kind)
		strings.write_string(&b, `,"label":`)
		json_quote(&b, x.label)
		strings.write_byte(&b, '}')
	}
	fmt.sbprintf(&b, `],"background_count":%d}`, n)
	return strings.to_string(b)
}

// A task's row in its panel: its description, else its command with secret-looking parts masked.
@(private = "file")
bg_label :: proc(b: Bg) -> string {
	if b.desc != "" do return b.desc
	if b.cmd != "" do return b.cmd
	return b.id
}

// A command line with what looks secret masked (temp): KEY=… for assignments whose name says
// TOKEN, KEY, SECRET, PASSWORD, PASSWD or AUTH; the value after --token, --password, --api-key
// (also as --token=…); and an Authorization header's value. A heuristic, not a guarantee: the
// panel shows Claude's own command, as pi's shell panel does.
claude_mask_secrets :: proc(cmd: string) -> string {
	secret_name :: proc(name: string) -> bool {
		if name == "" do return false
		for ch in transmute([]u8)name do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_' || ch == '-') do return false
		up := strings.to_upper(name, context.temp_allocator)
		for k in ([]string{"TOKEN", "KEY", "SECRET", "PASSWORD", "PASSWD", "AUTH"}) do if strings.contains(up, k) do return true
		return false
	}
	FLAGS :: [?]string{"--token", "--password", "--api-key"}
	b := strings.builder_make(context.temp_allocator)
	words := strings.split(cmd, " ", context.temp_allocator)
	mask_next := false
	for w, i in words {
		if i > 0 do strings.write_byte(&b, ' ')
		if mask_next && w != "" {
			strings.write_string(&b, "…")
			mask_next = false
			continue
		}
		lw := strings.to_lower(w, context.temp_allocator)
		flag := false
		for f in FLAGS {
			if lw == f {
				mask_next, flag = true, true
			} else if strings.has_prefix(lw, f) && len(lw) > len(f) && lw[len(f)] == '=' {
				fmt.sbprintf(&b, "%s=…", w[:len(f)])
				flag = true
			}
		}
		if flag {
			if mask_next do strings.write_string(&b, w)
			continue
		}
		if eq := strings.index_byte(w, '='); eq > 0 && secret_name(strings.trim_left(w[:eq], "'\"")) {
			fmt.sbprintf(&b, "%s=…", w[:eq])
			continue
		}
		strings.write_string(&b, w)
	}
	out := strings.to_string(b)
	// an Authorization header: its value up to the closing quote (or the word's end)
	for from := 0; true; {
		low := strings.to_lower(out[from:], context.temp_allocator)
		at := strings.index(low, "authorization:")
		if at < 0 do break
		start := from + at + len("authorization:")
		quote: u8 = 0
		if from + at > 0 && (out[from + at - 1] == '\'' || out[from + at - 1] == '"') do quote = out[from + at - 1]
		end := start
		for end < len(out) && (quote != 0 ? out[end] != quote : out[end] != ' ') do end += 1
		if end == start || strings.trim_space(out[start:end]) == "…" {
			from = end
			if from >= len(out) do break
			continue
		}
		out = strings.concatenate({out[:start], " …", out[end:]}, context.temp_allocator)
		from = start + len(" …")
	}
	return out
}

// Tests.
claude_launches_count :: proc(tab_id: u64) -> int {
	w, has := claude_work[tab_id]
	return has ? len(w.launches) : 0
}

// Untrusted text as one bounded line: control, bidi and invisible characters gone (temp).
@(private = "file")
clean :: proc(s: string, n: int) -> string {
	return cut_utf8(strings.trim_space(one_line(s, context.temp_allocator)), n)
}

// A task's or agent's id: what Claude Code makes them (letters, digits, - _ . :), bounded.
@(private = "file")
key_ok :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > CLAUDE_KEY_MAX do return false
	for ch in transmute([]u8)id do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '_' || ch == '.' || ch == ':') do return false
	return true
}

@(private = "file")
todo_state :: proc(s: string) -> (Todo_State, bool) {
	switch s {
	case "pending":     return .Pending, true
	case "in_progress": return .In_Progress, true
	case "completed":   return .Completed, true
	case "deleted":     return .Deleted, true
	}
	return .Pending, false
}

// ---- the panels ----

// The tab whose panels the right column shows: the active tab when it is a Claude tab, else the
// session's pi tab (nil = none).
right_panels_tab :: proc(s: ^Open_Session) -> ^Tab {
	if s == nil do return nil
	_, tab, _ := find_tab(s.active_tab)
	if tab != nil {
		if _, is := tab.kind.(Claude_Tab); is do return tab
	}
	return session_pi_tab(s)
}

@(private = "file")
row :: proc(rows: ^[dynamic]Panel_Row, text: string, tone := Panel_Tone.Normal, head := false) {
	append(rows, Panel_Row{text = strings.clone(cut_utf8(text, PANEL_TEXT_MAX)), tone = tone, head = head})
}

// A subagent's time: "42s", "1m 05s", "1h 02m"; "" under a second.
@(private = "file")
span :: proc(from, to: time.Tick) -> string {
	if from == {} do return ""
	secs := int(time.tick_diff(from, to) / time.Second)
	switch {
	case secs < 1:    return ""
	case secs < 60:   return fmt.tprintf("%ds", secs)
	case secs < 3600: return fmt.tprintf("%dm %02ds", secs / 60, secs % 60)
	}
	return fmt.tprintf("%dh %02dm", secs / 3600, (secs % 3600) / 60)
}

// The tab's panels again from its work: Subagents, Background, then Todos (pi's order); an empty
// one is not shown. now: running subagents' times.
@(private = "file")
render :: proc(tab: ^Tab, now := time.Tick{}) {
	now := now == {} ? time.tick_now() : now
	tab_clear_panels(tab)
	w, has := &claude_work[tab.id]
	if !has do return
	w.drawn = now
	if len(w.agents) > 0 {
		p := Panel{id = strings.clone("subagents"), title = strings.clone("Subagents")}
		running := 0
		for a in w.agents do if !a.done do running += 1
		row(&p.rows, running > 0 ? fmt.tprintf("Subagents · %d running", running) : "Subagents", head = true)
		for a in w.agents {
			kind := a.kind != "" ? a.kind : "subagent"
			line := strings.builder_make(context.temp_allocator)
			strings.write_string(&line, a.done ? "✓ " : "● ")
			strings.write_string(&line, kind)
			if d := span(a.started, a.done ? a.ended : now); d != "" do fmt.sbprintf(&line, " · %s", d)
			if !a.done && a.tool != "" do fmt.sbprintf(&line, " · %s", a.tool)
			if a.done && a.tools > 0 do fmt.sbprintf(&line, " · %d tool%s", a.tools, a.tools == 1 ? "" : "s")
			row(&p.rows, strings.to_string(line), a.done ? .Success : .Accent)
			if a.desc != "" do row(&p.rows, fmt.tprintf("  %s", a.desc), .Muted)
			// its own todos: the count, and while it runs the items
			live, done := a.todo_more, 0
			for t in a.todos do if t.state != .Deleted {
				live += 1
				if t.state == .Completed do done += 1
			}
			if live == 0 do continue
			row(&p.rows, fmt.tprintf("  Todos %d/%d", done, live), .Muted)
			if a.done do continue
			shown := 0
			for t in a.todos {
				if t.state == .Deleted do continue
				if shown >= CLAUDE_AGENT_TODOS_SHOWN do break
				switch t.state {
				case .In_Progress: row(&p.rows, fmt.tprintf("  ▸ %s", t.active != "" ? t.active : t.text), .Accent)
				case .Completed:   row(&p.rows, fmt.tprintf("  ✓ %s", t.text), .Dim)
				case .Pending:     row(&p.rows, fmt.tprintf("  ○ %s", t.text))
				case .Deleted:
				}
				shown += 1
			}
			if live > shown do row(&p.rows, fmt.tprintf("  +%d more", live - shown), .Muted)
		}
		append(&tab.panels, p)
	}
	// background work (subagents' own tasks are the Subagents panel's)
	shown_bg, running_bg := 0, 0
	for b in w.bg do if b.kind != "subagent" {
		shown_bg += 1
		if b.running do running_bg += 1
	}
	running_bg += w.bg_more
	if shown_bg + len(w.crons) > 0 {
		p := Panel{id = strings.clone("background"), title = strings.clone("Background")}
		head := running_bg > 0 ? fmt.tprintf("Background · %d running", running_bg) : "Background"
		row(&p.rows, head, head = true)
		for b in w.bg do if b.kind != "subagent" && b.running do row(&p.rows, fmt.tprintf("● %s · %s", b.kind, bg_label(b)), .Accent)
		for b in w.bg do if b.kind != "subagent" && !b.running do row(&p.rows, fmt.tprintf("✓ %s · %s", b.kind, bg_label(b)), .Success)
		for c in w.crons {
			row(&p.rows, fmt.tprintf("⏲ %s · %s", c.schedule != "" ? c.schedule : c.id, c.recurring ? "repeats" : "once"))
			if c.prompt != "" do row(&p.rows, fmt.tprintf("  %s", c.prompt), .Muted)
		}
		if w.bg_more > 0 do row(&p.rows, fmt.tprintf("+%d more running", w.bg_more), .Muted)
		if w.bg_snap do row(&p.rows, "As of Claude's last turn", .Dim)
		row(&p.rows, "Deckhand can't stop these: ask Claude", .Dim)
		append(&tab.panels, p)
	}
	live, done := 0, 0
	for t in w.todos {
		if t.state == .Deleted do continue
		live += 1
		if t.state == .Completed do done += 1
	}
	if live > 0 {
		p := Panel{id = strings.clone("todos"), title = strings.clone("Todos")}
		row(&p.rows, fmt.tprintf("Todos %d/%d", done, live + w.more), head = true)
		for t in w.todos {
			text := t.text != "" ? t.text : fmt.tprintf("task %s", t.key)
			switch t.state {
			case .In_Progress: row(&p.rows, fmt.tprintf("▸ %s", t.active != "" ? t.active : text), .Accent)
			case .Completed:   row(&p.rows, fmt.tprintf("✓ %s", text), .Dim)
			case .Pending:     row(&p.rows, fmt.tprintf("○ %s", text))
			case .Deleted:
			}
		}
		if w.more > 0 do row(&p.rows, fmt.tprintf("+%d more", w.more), .Muted)
		append(&tab.panels, p)
	}
}

// claude.session: a new conversation (anything but a compaction) starts with nothing listed.
claude_work_session :: proc(tab: ^Tab, source: string) {
	if source == "compact" do return
	if _, has := claude_work[tab.id]; !has do return
	claude_work_reset(tab.id)
	render(tab)
}

// The user's next message: finished subagents and background tasks leave the panels; running
// ones stay.
claude_work_submitted :: proc(tab: ^Tab) {
	w, has := &claude_work[tab.id]
	if !has do return
	any := false
	for i := len(w.agents) - 1; i >= 0; i -= 1 {
		a := w.agents[i]
		if !a.done do continue
		agent_free(a)
		ordered_remove(&w.agents, i)
		any = true
	}
	for i := len(w.bg) - 1; i >= 0; i -= 1 {
		if w.bg[i].running do continue
		bg_free(w.bg[i])
		ordered_remove(&w.bg, i)
		any = true
	}
	if any do render(tab)
}

// Frame upkeep (claude_wait_tick): running subagents' times move on, redrawn once a second.
claude_panels_tick :: proc(now := time.Tick{}) {
	now := now == {} ? time.tick_now() : now
	for id, &w in claude_work {
		running := false
		for a in w.agents do if !a.done && a.started != {} && time.tick_diff(a.last, now) < CLAUDE_AGENT_STALE do running = true
		if !running || time.tick_diff(w.drawn, now) < CLAUDE_PANELS_EVERY do continue
		if _, tab, _ := find_tab(id); tab != nil {
			render(tab, now)
			window_state_changed()
		}
	}
}

@(private = "file")
find_todo :: proc(w: ^Work, key: string) -> ^Todo {
	for &t in w.todos do if t.key == key do return &t
	return nil
}

// Room for one more task: a deleted one goes first, then the oldest completed. False: all open.
@(private = "file")
todo_room :: proc(w: ^Work) -> bool {
	if len(w.todos) < CLAUDE_TODOS_MAX do return true
	for want in ([]Todo_State{.Deleted, .Completed}) {
		for t, i in w.todos do if t.state == want {
			todo_free(t)
			ordered_remove(&w.todos, i)
			return true
		}
	}
	return false
}

@(private = "file")
agent_room :: proc(w: ^Work) {
	if len(w.agents) < CLAUDE_AGENTS_MAX do return
	at := 0
	for a, i in w.agents do if a.done {
		at = i
		break
	}
	agent_free(w.agents[at])
	ordered_remove(&w.agents, at)
}

@(private = "file")
find_agent :: proc(w: ^Work, id: string) -> ^Agent {
	for &a in w.agents do if a.id == id do return &a
	return nil
}

// Room for one more background task: a finished one goes; a running one never does (false: full
// of running ones, the caller counts it in bg_more instead).
@(private = "file")
bg_room :: proc(w: ^Work) -> bool {
	if len(w.bg) < CLAUDE_BG_MAX do return true
	for b, i in w.bg do if !b.running {
		bg_free(b)
		ordered_remove(&w.bg, i)
		return true
	}
	return false
}

@(private = "file")
find_bg :: proc(w: ^Work, id: string) -> ^Bg {
	for &b in w.bg do if b.id == id do return &b
	return nil
}

// A snapshot's task's entry: its id; else, for a shell, a launch not yet in a snapshot whose id
// one contains the other's as prefix or suffix (Bash's backgroundTaskId and the Stop's id are
// documented separately: if their formats ever differ by a prefix, they still pair; anything else
// shows twice until the next snapshot ends the launch).
@(private = "file")
match_bg :: proc(w: ^Work, id, kind: string) -> int {
	for b, i in w.bg do if b.id == id do return i
	if kind != "shell" || len(id) < 4 do return -1
	for b, i in w.bg {
		if !b.launch || len(b.id) < 4 do continue
		if strings.has_prefix(id, b.id) || strings.has_suffix(id, b.id) || strings.has_prefix(b.id, id) || strings.has_suffix(b.id, id) do return i
	}
	return -1
}

// claude.turn's end (claude_status.odin): a Stop that came without a snapshot (an older Claude Code,
// or one lost) leaves its launches unconfirmed: they go (nothing would ever end them). True if
// the panel changed.
claude_work_turn_end :: proc(tab: ^Tab) -> bool {
	w, has := &claude_work[tab.id]
	if !has do return false
	if w.snap_turn {
		w.snap_turn = false
		return false
	}
	any := false
	for i := len(w.bg) - 1; i >= 0; i -= 1 {
		if !w.bg[i].launch do continue
		bg_free(w.bg[i])
		ordered_remove(&w.bg, i)
		any = true
	}
	if any do render(tab)
	return any
}

// A cleaned replacement for a kept string, when the new one says something.
@(private = "file")
set_text :: proc(dst: ^string, text: string, n: int) {
	v := clean(text, n)
	if v == "" || v == dst^ do return
	delete(dst^)
	dst^ = strings.clone(v)
}

// TodoWrite's list into kept todos (cleaned, at most max; the rest counted).
@(private = "file")
todos_fill :: proc(list: ^[dynamic]Todo, more: ^int, todos: []Claude_Todo_In, max_n, seq: u64) {
	for in_ in todos {
		text := clean(in_.content, CLAUDE_ITEM_TEXT_MAX)
		if text == "" do continue
		st, _ := todo_state(in_.status)
		if st == .Deleted do continue
		if u64(len(list)) >= max_n {
			more^ += 1
			continue
		}
		append(list, Todo{text = strings.clone(text), active = strings.clone(clean(in_.active_form, CLAUDE_ITEM_TEXT_MAX)), state = st, seq = seq})
	}
}

// ---- apply ----

claude_extra_apply :: proc(cmd: Command, caller: Caller, request_id: u64) -> (Result, bool) {
	#partial switch c in cmd {
	case Claude_Restart:
		s, tab, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		if tab_held_away(tab) != 0 do return fail("this Claude still runs in the session holder, which isn't answering: quit and reopen Deckhand to get it back"), false
		switch tab.status {
		case .Running:     return fail("Claude is running in this tab"), false
		case .Not_Started: return fail("Claude has not started in this tab yet: it starts when its session is shown"), false
		case .Exited:
		}
		if restart_waiting(tab.id) do return fail("this tab is restarting"), false
		if s.missing do return fail("this session is gone"), false
		// the saved flags are the user's to replay (CLAUDE.md §3)
		r := claude_tab_restart(s, tab, caller.kind == .UI, c.pick_model && caller.kind == .UI) // Restart with model… is the user's
		return r, r.ok // a refusal (still not installed, could not start) changes nothing
	case Claude_Todos:
		_, tab, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		if tab.status != .Running do return fail("Claude is not running in this tab"), false
		if len(c.todos) > CLAUDE_TODOS_IN_MAX do return fail(fmt.tprintf("at most %d todos", CLAUDE_TODOS_IN_MAX)), false
		w := work_of(tab.id)
		if c.agent_id != "" {
			// a subagent's own list, under it; a subagent pi-desk does not know (its start not
			// here yet, an in-process teammate): nowhere, never the main list
			if !key_ok(c.agent_id) do return fail("agent_id must be an agent id"), false
			a := find_agent(w, c.agent_id)
			if a == nil || (c.seq != 0 && c.seq < a.todo_seq) do return {ok = true}, false
			if c.seq != 0 do a.todo_seq = c.seq
			a.last = time.tick_now()
			for t in a.todos do todo_free(t)
			clear(&a.todos)
			a.todo_more = 0
			todos_fill(&a.todos, &a.todo_more, c.todos, CLAUDE_AGENT_TODOS_MAX, c.seq)
			render(tab)
			return {ok = true}, true
		}
		if c.seq != 0 && c.seq < w.list_seq do return {ok = true}, false // an older list (async hooks)
		if c.seq != 0 do w.list_seq = c.seq
		todos_clear(w)
		todos_fill(&w.todos, &w.more, c.todos, CLAUDE_TODOS_MAX, c.seq)
		render(tab)
		return {ok = true}, true
	case Claude_Task:
		_, tab, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		if tab.status != .Running do return fail("Claude is not running in this tab"), false
		if !key_ok(c.task_id) do return fail("task_id must be a task id"), false
		switch c.event {
		case "created", "updated", "completed":
		case: return fail("event must be created, updated or completed"), false
		}
		w := work_of(tab.id)
		t := find_todo(w, c.task_id)
		if t == nil {
			if !todo_room(w) do return fail(fmt.tprintf("at most %d tasks", CLAUDE_TODOS_MAX)), false
			append(&w.todos, Todo{key = strings.clone(c.task_id)})
			t = &w.todos[len(w.todos) - 1]
		}
		// its name whenever it has none; a change only from a report not older than the last
		newer := c.seq == 0 || c.seq >= t.seq
		if subject := clean(c.subject, CLAUDE_ITEM_TEXT_MAX); subject != "" && (t.text == "" || (c.event == "updated" && newer)) {
			delete(t.text)
			t.text = strings.clone(subject)
		}
		if active := clean(c.active_form, CLAUDE_ITEM_TEXT_MAX); active != "" && (t.active == "" || (c.event == "updated" && newer)) {
			delete(t.active)
			t.active = strings.clone(active)
		}
		if c.event != "created" && newer {
			if c.event == "completed" do t.state = .Completed
			else if st, ok := todo_state(c.status); ok do t.state = st
			t.seq = c.seq
		} else if c.event == "created" && t.seq == 0 do t.seq = c.seq
		render(tab)
		return {ok = true}, true
	case Claude_Subagent:
		_, tab, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		if tab.status != .Running do return fail("Claude is not running in this tab"), false
		kind := clean(c.agent_type, CLAUDE_KIND_MAX)
		w := work_of(tab.id)
		switch c.event {
		case "launch":
			desc := clean(c.description, CLAUDE_ITEM_TEXT_MAX)
			// its SubagentStart came first: the oldest running one of that type without a description
			for &a in w.agents do if !a.done && a.desc == "" && a.kind == kind {
				a.desc = strings.clone(desc)
				render(tab)
				return {ok = true}, true
			}
			if len(w.launches) >= CLAUDE_LAUNCHES_MAX {
				delete(w.launches[0].kind)
				delete(w.launches[0].desc)
				ordered_remove(&w.launches, 0)
			}
			append(&w.launches, Launch{kind = strings.clone(kind), desc = strings.clone(desc)})
			return {ok = true}, false
		case "tool":
			// its current tool (PreToolUse inside it); an agent pi-desk does not know: nothing
			if !key_ok(c.agent_id) do return fail("agent_id must be an agent id"), false
			a := find_agent(w, c.agent_id)
			if a == nil || a.done do return {ok = true}, false
			a.tools += 1
			a.last = time.tick_now()
			if c.seq == 0 || c.seq >= a.tool_seq {
				a.tool_seq = c.seq
				set_text(&a.tool, c.tool_name, CLAUDE_KIND_MAX)
			}
			render(tab)
			return {ok = true}, true
		case "start", "stop":
			if !key_ok(c.agent_id) do return fail("agent_id must be an agent id"), false
			now := time.tick_now()
			at := -1
			for a, i in w.agents do if a.id == c.agent_id do at = i
			if at >= 0 {
				a := &w.agents[at]
				if a.kind == "" && kind != "" do a.kind = strings.clone(kind)
				if c.event == "stop" && !a.done { 	// a start after its stop changes nothing
					a.done = true
					a.ended = now
				}
			} else {
				agent_room(w)
				a := Agent{id = strings.clone(c.agent_id), kind = strings.clone(kind), done = c.event == "stop", started = now, ended = now, last = now}
				// its Agent tool call: the oldest waiting one of that type
				for l, i in w.launches do if l.kind == kind {
					a.desc = l.desc
					delete(l.kind)
					ordered_remove(&w.launches, i)
					break
				}
				append(&w.agents, a)
			}
			render(tab)
			return {ok = true}, true
		}
		return fail("event must be launch, start, stop or tool"), false
	case Claude_Background:
		_, tab, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		if tab.status != .Running do return fail("Claude is not running in this tab"), false
		w := work_of(tab.id)
		switch c.event {
		case "launch":
			if !key_ok(c.task_id) do return fail("task_id must be a task id"), false
			b := find_bg(w, c.task_id)
			if b == nil {
				if !bg_room(w) do return {ok = true}, false // full of running ones: the next snapshot counts it
				kind := clean(c.kind, 32)
				// launched before the newest snapshot, which did not list it: it already ended
				over := w.bg_snap && c.seq != 0 && c.seq < w.bg_seq
				append(&w.bg, Bg{id = strings.clone(c.task_id), kind = strings.clone(kind != "" ? kind : "shell"), running = !over, launch = true, seq = c.seq})
				b = &w.bg[len(w.bg) - 1]
			}
			set_text(&b.desc, c.description, CLAUDE_ITEM_TEXT_MAX)
			set_text(&b.cmd, claude_mask_secrets(clean(c.command, CLAUDE_ITEM_TEXT_MAX)), CLAUDE_ITEM_TEXT_MAX)
			render(tab)
			return {ok = true}, true
		case "snapshot":
			if len(c.tasks) > CLAUDE_BG_IN_MAX || len(c.crons) > CLAUDE_CRONS_IN_MAX do return fail("too many background tasks"), false
			if c.seq != 0 && c.seq < w.bg_seq do return {ok = true}, false // an older snapshot (async SubagentStop)
			if c.seq != 0 do w.bg_seq = c.seq
			w.bg_snap, w.snap_turn = true, true
			w.bg_more = 0
			// match each listed task to its entry first (ids, or a launch: match_bg)
			hit := make([]int, len(c.tasks), context.temp_allocator)
			for x, i in c.tasks do hit[i] = key_ok(x.id) ? match_bg(w, x.id, clean(x.kind, 32)) : -1
			// what it no longer lists ended, but a launch newer than it
			for &b, j in w.bg {
				listed := false
				for h in hit do if h == j do listed = true
				if listed || (b.launch && c.seq != 0 && b.seq > c.seq) do continue
				b.running = false
			}
			// the listed ones it knew (indices still valid: nothing removed yet), then new ones
			for pass in 0 ..< 2 do for x, i in c.tasks {
				if !key_ok(x.id) || (pass == 0) != (hit[i] >= 0) do continue
				running := bg_running_status(x.status)
				b: ^Bg
				if pass == 0 do b = &w.bg[hit[i]]
				else {
					if find_bg(w, x.id) != nil do continue // listed twice
					if !bg_room(w) {
						if running do w.bg_more += 1
						continue
					}
					kind := clean(x.kind, 32)
					append(&w.bg, Bg{id = strings.clone(x.id), kind = strings.clone(kind != "" ? kind : "task")})
					b = &w.bg[len(w.bg) - 1]
				}
				b.running = running
				b.launch = false
				set_text(&b.desc, x.description, CLAUDE_ITEM_TEXT_MAX)
				set_text(&b.cmd, claude_mask_secrets(clean(x.command, CLAUDE_ITEM_TEXT_MAX)), CLAUDE_ITEM_TEXT_MAX)
			}
			crons_clear(w)
			for x in c.crons {
				if len(w.crons) >= CLAUDE_CRONS_MAX do break
				if !key_ok(x.id) do continue
				append(&w.crons, Cron{id = strings.clone(x.id), schedule = strings.clone(clean(x.schedule, 64)), prompt = strings.clone(clean(x.prompt, CLAUDE_ITEM_TEXT_MAX)), recurring = x.recurring})
			}
			render(tab)
			return {ok = true}, true
		}
		return fail("event must be launch or snapshot"), false
	}
	return fail("not a Claude command"), false
}

// ---- wire ----

claude_extra_tab :: proc(cmd: Command) -> u64 {
	#partial switch c in cmd {
	case Claude_Todos:    return c.tab_id
	case Claude_Task:     return c.tab_id
	case Claude_Subagent: return c.tab_id
	case Claude_Background: return c.tab_id
	case Claude_Restart:  return c.tab_id
	}
	return 0
}

claude_extra_type :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case Claude_Todos:    return "claude.todos"
	case Claude_Task:     return "claude.task"
	case Claude_Subagent: return "claude.subagent"
	case Claude_Background: return "claude.background"
	case Claude_Restart:  return "claude_restart"
	}
	return ""
}

// For events and the command log: counts, events and ids, never Claude's text.
claude_extra_write :: proc(b: ^strings.Builder, cmd: Command) {
	#partial switch c in cmd {
	case Claude_Restart:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
		if c.pick_model do strings.write_string(b, `,"pick_model":true`)
	case Claude_Todos:
		fmt.sbprintf(b, `,"tab_id":%d,"todos":%d,"seq":%d`, c.tab_id, len(c.todos), c.seq)
		if c.agent_id != "" {
			strings.write_string(b, `,"agent_id":`)
			json_quote(b, cut_utf8(c.agent_id, CLAUDE_KEY_MAX))
		}
	case Claude_Background:
		fmt.sbprintf(b, `,"tab_id":%d,"event":`, c.tab_id)
		json_quote(b, cut_utf8(c.event, 16))
		if c.task_id != "" {
			strings.write_string(b, `,"task_id":`)
			json_quote(b, cut_utf8(c.task_id, CLAUDE_KEY_MAX))
		}
		fmt.sbprintf(b, `,"tasks":%d,"crons":%d,"seq":%d`, len(c.tasks), len(c.crons), c.seq)
	case Claude_Task:
		fmt.sbprintf(b, `,"tab_id":%d,"event":`, c.tab_id)
		json_quote(b, cut_utf8(c.event, 16))
		strings.write_string(b, `,"task_id":`)
		json_quote(b, cut_utf8(c.task_id, CLAUDE_KEY_MAX))
		if c.status != "" {
			strings.write_string(b, `,"status":`)
			json_quote(b, cut_utf8(c.status, 16))
		}
	case Claude_Subagent:
		fmt.sbprintf(b, `,"tab_id":%d,"event":`, c.tab_id)
		json_quote(b, cut_utf8(c.event, 16))
		if c.agent_id != "" {
			strings.write_string(b, `,"agent_id":`)
			json_quote(b, cut_utf8(c.agent_id, CLAUDE_KEY_MAX))
		}
	}
}

claude_extra_clone :: proc(cmd: Command, allocator := context.allocator) -> Command {
	s :: proc(v: string, a := context.allocator) -> string {return strings.clone(v, a)}
	#partial switch c in cmd {
	case Claude_Todos:
		out := make([]Claude_Todo_In, len(c.todos), allocator)
		for t, i in c.todos do out[i] = {content = s(t.content, allocator), status = s(t.status, allocator), active_form = s(t.active_form, allocator)}
		return Claude_Todos{tab_id = c.tab_id, todos = out, agent_id = s(c.agent_id, allocator), seq = c.seq}
	case Claude_Task:
		return Claude_Task{tab_id = c.tab_id, event = s(c.event, allocator), task_id = s(c.task_id, allocator), subject = s(c.subject, allocator), active_form = s(c.active_form, allocator), status = s(c.status, allocator), seq = c.seq}
	case Claude_Subagent:
		return Claude_Subagent{tab_id = c.tab_id, event = s(c.event, allocator), agent_id = s(c.agent_id, allocator), agent_type = s(c.agent_type, allocator), description = s(c.description, allocator), tool_name = s(c.tool_name, allocator), seq = c.seq}
	case Claude_Background:
		tasks := make([]Claude_Bg_In, len(c.tasks), allocator)
		for x, i in c.tasks do tasks[i] = {id = s(x.id, allocator), kind = s(x.kind, allocator), status = s(x.status, allocator), description = s(x.description, allocator), command = s(x.command, allocator)}
		crons := make([]Claude_Cron_In, len(c.crons), allocator)
		for x, i in c.crons do crons[i] = {id = s(x.id, allocator), schedule = s(x.schedule, allocator), prompt = s(x.prompt, allocator), recurring = x.recurring}
		return Claude_Background{tab_id = c.tab_id, event = s(c.event, allocator), task_id = s(c.task_id, allocator), kind = s(c.kind, allocator), description = s(c.description, allocator), command = s(c.command, allocator), tasks = tasks, crons = crons, seq = c.seq}
	}
	return cmd
}

claude_extra_free :: proc(cmd: Command, allocator := context.allocator) {
	#partial switch c in cmd {
	case Claude_Todos:
		for t in c.todos {
			delete(t.content, allocator)
			delete(t.status, allocator)
			delete(t.active_form, allocator)
		}
		delete(c.todos, allocator)
		delete(c.agent_id, allocator)
	case Claude_Task:
		delete(c.event, allocator)
		delete(c.task_id, allocator)
		delete(c.subject, allocator)
		delete(c.active_form, allocator)
		delete(c.status, allocator)
	case Claude_Subagent:
		delete(c.event, allocator)
		delete(c.agent_id, allocator)
		delete(c.agent_type, allocator)
		delete(c.description, allocator)
		delete(c.tool_name, allocator)
	case Claude_Background:
		for x in c.tasks {
			delete(x.id, allocator)
			delete(x.kind, allocator)
			delete(x.status, allocator)
			delete(x.description, allocator)
			delete(x.command, allocator)
		}
		delete(c.tasks, allocator)
		for x in c.crons {
			delete(x.id, allocator)
			delete(x.schedule, allocator)
			delete(x.prompt, allocator)
		}
		delete(c.crons, allocator)
		delete(c.event, allocator)
		delete(c.task_id, allocator)
		delete(c.kind, allocator)
		delete(c.description, allocator)
		delete(c.command, allocator)
	}
}
