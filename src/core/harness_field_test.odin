package core

// A Claude tab's harness (claude.odin: Harness, .Claude or .Codex) where it meets a wire: the
// state stream carries it as the codex bool it replaced (state_wire.odin: STATE_WIRE_CODEX_BOOLS),
// byte for byte what the bool wrote, for mirrors on other versions; the command wire's harness
// (json_read.odin) and every place a left-out harness used to mean Claude Code read as .Claude,
// never .Pi (Harness's zero value).

import "core:encoding/json"
import "core:strings"
import "core:testing"

// What the state stream wrote for these values while the field was `codex: bool` (a6efb36).
@(private = "file")
OLD_CLAUDE_TAB :: `{"session_id":"s1","args":[],"readonly":false,"guard_stopped":false,"turn":"unknown","held":[],"model":"","ended":"none","account":"/a","resume_path":"","codex":false}`
@(private = "file")
OLD_CODEX_TAB :: `{"session_id":"s1","args":[],"readonly":false,"guard_stopped":false,"turn":"unknown","held":[],"model":"","ended":"none","account":"/a","resume_path":"","codex":true}`
@(private = "file")
OLD_CLAUDE_RECORD :: `{"id":"r1","cwd":"","project":"/p","title":"","used":3,"args":[],"named":false,"transcript":"","model":"","readonly":false,"account":"","codex":false}`
@(private = "file")
OLD_CODEX_RECORD :: `{"id":"r1","cwd":"","project":"/p","title":"","used":3,"args":[],"named":false,"transcript":"","model":"","readonly":false,"account":"","codex":true}`


@(test)
harness_state_wire_codex_bool :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	for h in ([2]Harness{.Claude, .Codex}) {
		want_tab := h == .Codex ? OLD_CODEX_TAB : OLD_CLAUDE_TAB
		want_rec := h == .Codex ? OLD_CODEX_RECORD : OLD_CLAUDE_RECORD

		ct := Claude_Tab{session_id = "s1", account = "/a", harness = h}
		strings.builder_reset(&b)
		wire_write(&b, &ct, type_info_of(Claude_Tab))
		testing.expect_value(t, strings.to_string(b), want_tab)
		// inside a tab's kind too (the tabs:<id> section's form)
		tab := Tab{id = 7, kind = ct, title = "T"}
		strings.builder_reset(&b)
		wire_write(&b, &tab, type_info_of(Tab))
		testing.expectf(t, strings.contains(strings.to_string(b), strings.concatenate({`"kind":{"claude_tab":`, want_tab, "}"}, context.temp_allocator)), "the tab's kind: %s", strings.to_string(b))

		rec := Claude_Record{id = "r1", project = "/p", used = 3, harness = h}
		strings.builder_reset(&b)
		wire_write(&b, &rec, type_info_of(Claude_Record))
		testing.expect_value(t, strings.to_string(b), want_rec)

		// read back: the harness it was
		wire_read_budget(want_tab)
		v, err := json.parse_string(want_tab, parse_integers = true, allocator = context.temp_allocator)
		testing.expect_value(t, err, json.Error.None)
		back: Claude_Tab
		testing.expect_value(t, wire_read(v, &back, type_info_of(Claude_Tab), context.temp_allocator), "")
		testing.expect_value(t, back.harness, h)
		testing.expect_value(t, back.account, "/a")
		wire_read_budget(want_rec)
		v, err = json.parse_string(want_rec, parse_integers = true, allocator = context.temp_allocator)
		testing.expect_value(t, err, json.Error.None)
		rback: Claude_Record
		testing.expect_value(t, wire_read(v, &rback, type_info_of(Claude_Record), context.temp_allocator), "")
		testing.expect_value(t, rback.harness, h)
	}
	// an older peer's tab without the field: Claude Code's, as the bool's false was
	wire_read_budget(`{"session_id":"s2"}`)
	v, _ := json.parse_string(`{"session_id":"s2"}`, parse_integers = true, allocator = context.temp_allocator)
	old: Claude_Tab
	testing.expect_value(t, wire_read(v, &old, type_info_of(Claude_Tab), context.temp_allocator), "")
	testing.expect_value(t, old.harness, Harness.Claude)
	// not a bool: refused, as the bool's reader refused it
	wire_read_budget(`{"session_id":"s2","codex":"codex"}`)
	v, _ = json.parse_string(`{"session_id":"s2","codex":"codex"}`, parse_integers = true, allocator = context.temp_allocator)
	bad: Claude_Tab
	testing.expect(t, wire_read(v, &bad, type_info_of(Claude_Tab), context.temp_allocator) != "")
	// never a "harness" key on the stream
	ct := Claude_Tab{harness = .Codex}
	strings.builder_reset(&b)
	wire_write(&b, &ct, type_info_of(Claude_Tab))
	testing.expect(t, !strings.contains(strings.to_string(b), `"harness"`))
}

// Every command that names a harness for a Claude tab reads a left-out one as .Claude (as the
// codex bool's false), "codex" as .Codex, and writes .Claude as nothing (the wire as before).
@(test)
harness_command_defaults :: proc(t: ^testing.T) {
	CASES :: [?]string {
		`{"type":"new_claude_tab","session":1`,
		`{"type":"new_claude_session","project_id":1`,
		`{"type":"set_claude_default_flags","skip_permissions":false`,
		`{"type":"add_claude_account","dir":"/x"`,
		`{"type":"rename_claude_account","account":"a","label":"b"`,
		`{"type":"remove_claude_account","account":"a"`,
		`{"type":"set_claude_account_default","account":"a"`,
	}
	harness_of :: proc(cmd: Command) -> (Harness, bool) {
		#partial switch c in cmd {
		case New_Claude_Tab:             return c.harness, true
		case New_Claude_Session:         return c.harness, true
		case Set_Claude_Default_Flags:   return c.harness, true
		case Add_Claude_Account:         return c.harness, true
		case Rename_Claude_Account:      return c.harness, true
		case Remove_Claude_Account:      return c.harness, true
		case Set_Claude_Account_Default: return c.harness, true
		}
		return .Pi, false
	}
	for c in CASES {
		for tail, i in ([3]string{"}", `,"harness":"claude"}`, `,"harness":"codex"}`}) {
			text := strings.concatenate({c, tail}, context.temp_allocator)
			cmd, err := parse_command(text, context.temp_allocator)
			testing.expectf(t, err == "", "%s: %s", text, err)
			h, ok := harness_of(cmd)
			testing.expectf(t, ok && h == (i == 2 ? Harness.Codex : Harness.Claude), "%s: %v", text, h)
			js := command_json(cmd, true)
			testing.expectf(t, strings.contains(js, `"harness":"codex"`) == (i == 2), "%s wrote %s", text, js)
		}
	}
	// pi is no Claude tab's harness
	_, err := parse_command(`{"type":"new_claude_tab","session":1,"harness":"pi"}`, context.temp_allocator)
	testing.expect_value(t, err, "harness must be claude or codex")
}

// A Restore_Session queued from another thread (inbox_submit copies it: command_clone) keeps each
// Claude tab's harness: a Codex tab is restored as Codex.
@(test)
harness_restore_session_clone :: proc(t: ^testing.T) {
	cmd := Restore_Session{project_id = 1, pi_session_id = "x", agent = .Claude, tabs = {
		{kind = .Claude, claude_id = "01a1d0d6-5353-7ff3-9308-ff91070ad5fd", harness = .Codex},
		{kind = .Claude, claude_id = "aaaa1111-0000-4000-8000-000000000001", harness = .Claude},
	}}
	c, is := command_clone(cmd, context.temp_allocator).(Restore_Session)
	testing.expect(t, is && len(c.tabs) == 2)
	if is && len(c.tabs) == 2 {
		testing.expect_value(t, c.tabs[0].harness, Harness.Codex)
		testing.expect_value(t, c.tabs[1].harness, Harness.Claude)
	}
}
