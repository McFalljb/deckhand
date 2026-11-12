package core

// Claude rows and tabs at parity with pi's (docs/CLAUDE.md §4b): the history entry's transcript
// path and model (SessionStart), the model's switches (PostModelSwitch: claude.model), the row's
// session info, Reveal and Copy path, the question and error dots (Stop, StopFailure), and the
// user's rename pushed to Claude Code as its session title.
//
// Deckhand still never reads Claude Code's files: the transcript path is only a name the hook
// reported, kept when it is a .jsonl under Claude's config dir's projects/ (real paths, so no `..`
// and no symlink out of it), checked again before Reveal or Copy path use it.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// How a Claude tab's last turn ended, per its hooks: a dot when OSC 7501 says nothing stronger.
Claude_Ended :: enum u8 {
	None,
	Question, // Stop: its last answer ends with a question (the CLI looks; the text never comes)
	Error, // StopFailure: the turn ended on an API error
}

// From the tab's own plugin: its model changed (PostModelSwitch; also restoring it on resume).
Claude_Model_Report :: struct {
	tab_id: u64,
	model:  string,
}

CLAUDE_MODEL_MAX :: 100
CLAUDE_TRANSCRIPT_MAX :: 4096

// A transcript path Claude reported, as its real path, if it is a .jsonl file under Claude's config
// dir's projects/ (no `..` or `.` parts, no control characters, and its real path, symlinks
// resolved, still inside); "" = not kept (temp). A new conversation's file may not exist yet: the
// part that exists is resolved.
claude_transcript_ok :: proc(path: string) -> string {
	if path == "" || len(path) > CLAUDE_TRANSCRIPT_MAX || !filepath.is_abs(path) do return ""
	for r in path do if r < 0x20 || r == 0x7f do return ""
	for part in strings.split(path, "/", context.temp_allocator) do if part == ".." || part == "." do return ""
	if !strings.has_suffix(path, ".jsonl") do return ""
	// under any account's projects/ (claude_accounts.odin): each one is Claude's config folder
	real := fs_real(path)
	for cfg in claude_account_dirs() {
		root := fs_real(strings.concatenate({cfg, "/projects"}, context.temp_allocator))
		if root == "" || real == root || !within(real, root) || !strings.has_suffix(real, ".jsonl") do continue
		return real
	}
	return ""
}

// The history entry's transcript, if it is still a file under Claude's projects/ (checked again
// at each use: it may have been replaced by a symlink out since).
claude_transcript_file :: proc(rec: ^Claude_Record) -> (path: string, err: string) {
	if rec.transcript == "" do return "", "Deckhand has no transcript path for this Claude session"
	p := claude_transcript_ok(rec.transcript)
	if p == "" do return "", "the transcript is not in Claude Code's projects folder"
	if fi, serr := os.stat(p, context.temp_allocator); serr != nil || fi.type != .Regular do return "", "the transcript file is gone"
	return p, ""
}

// A model name as one bounded token: letters, digits and - _ . : / @ [ ] ("" = not one).
claude_model_clean :: proc(model: string) -> string {
	if len(model) == 0 || len(model) > CLAUDE_MODEL_MAX do return ""
	for ch in transmute([]u8)model {
		ok := ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9'
		switch ch {
		case '-', '_', '.', ':', '/', '@', '[', ']': ok = true
		}
		if !ok do return ""
	}
	return model
}

// The Claude history entry a row of project_id is (not a pi session's file of it); nil = none.
claude_row_record :: proc(project_id: u64, id: string) -> ^Claude_Record {
	p := find_project(project_id)
	if p == nil || id == "" do return nil
	rec, _ := claude_record(id)
	if rec == nil || rec.project != p.cwd do return nil
	if find_session_file(p^, id) != "" do return nil // a pi session's id is its pi row
	return rec
}

// claude.session's extras (claude.odin, after the history entry moved to the front): the
// transcript path and model it reported; data {title} when the user named it (the hook gives it
// to Claude Code as its sessionTitle).
claude_rows_session :: proc(ct: ^Claude_Tab, c: Claude_Session_Report) -> string {
	if c.source != "compact" do ct.ended = .None // a new conversation (a compaction keeps its turn)
	rec, _ := claude_record(c.session_id)
	if rec == nil do return ""
	// the first path stays: a later report never repoints an entry's transcript (claude_transcript_ok)
	if p := claude_transcript_ok(c.transcript_path); p != "" && rec.transcript == "" {
		delete(rec.transcript)
		rec.transcript = strings.clone(p)
	}
	if m := claude_model_clean(c.model); m != "" {
		set_model(ct, rec, m)
	} else if rec.model == "" && ct.model != "" {
		rec.model = strings.clone(ct.model) // a new conversation (/clear) in the same process: same model
	}
	if !rec.named || rec.title == "" do return ""
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"title":`)
	json_quote(&b, rec.title)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
set_model :: proc(ct: ^Claude_Tab, rec: ^Claude_Record, m: string) {
	if ct != nil && ct.model != m {
		delete(ct.model)
		ct.model = strings.clone(m)
	}
	if rec != nil && rec.model != m {
		delete(rec.model)
		rec.model = strings.clone(m)
	}
}

// claude.turn's end of a turn (claude.odin): how it ended. True if that changed. A Stop (idle) is
// authoritative, also for a turn with no UserPromptSubmit (a background wake, /loop, after a
// compaction); only Notification's idle_prompt (idle a while after the Stop) leaves it as it is.
claude_rows_turn :: proc(ct: ^Claude_Tab, state: string, question, idle_prompt: bool) -> bool {
	was := ct.ended
	switch state {
	case "idle":                 if !idle_prompt do ct.ended = question ? .Question : .None
	case "error":                ct.ended = .Error
	case "submitted", "waiting": ct.ended = .None // a turn goes on
	}
	return ct.ended != was
}

claude_rows_apply :: proc(cmd: Command, caller: Caller) -> (Result, bool) {
	#partial switch c in cmd {
	case Claude_Model_Report:
		_, _, ct := claude_tab_of(c.tab_id)
		if ct == nil do return fail("no such Claude tab"), false
		m := claude_model_clean(c.model)
		if m == "" do return fail("model must be a model name (letters, digits and - _ . : / @ [ ], at most 100)"), false
		if ct.model == m do return {ok = true}, false
		rec, _ := claude_record(ct.session_id)
		set_model(ct, rec, m)
		return {ok = true}, true
	}
	return fail("not a Claude command"), false
}

// The tooltip line naming a Claude tab's model ("" = none).
claude_tab_tip :: proc(tab: Tab) -> string {
	ct, is := tab.kind.(Claude_Tab)
	if !is || ct.model == "" do return ""
	return fmt.tprintf("%s · model %s", ct.codex ? "Codex" : "Claude Code", ct.model)
}

// The snapshot's model of a Claude tab (claude_tab_json).
claude_rows_tab_json :: proc(b: ^strings.Builder, ct: Claude_Tab) {
	if ct.model != "" {
		strings.write_string(b, `,"model":`)
		json_quote(b, ct.model)
	}
}
