package core

// Read-only pi chats are enforced by pi itself, not only by pi-kit: every start of a chat's pi
// while Chats: read-only is on ends with pi's tool allowlist (PI_READONLY_ARGS), the same flags
// a read-only job gets. The live side (every start path's argv) is tests/scripts/pi-chat-readonly.sh.

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
chat_readonly_args :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved_projects, saved_ro := state.projects, state.settings.chats_readonly
	defer {
		delete(state.projects)
		state.projects, state.settings.chats_readonly = saved_projects, saved_ro
	}
	state.projects = {}
	chat := Project{id = new_id(), cwd = "/tmp/Chats", group = .Chats}
	proj := Project{id = new_id(), cwd = "/tmp/proj"}
	append(&state.projects, chat, proj)
	ro := PI_READONLY_ARGS
	testing.expect(t, slice.equal(ro[:], []string{"--tools", "read,grep,find,ls", "--exclude-tools", "mcp__*", "--no-mcp"}), "pi's read tools only, no bash, no MCP tools of any source")
	// a chat also keeps desk_show (display only: Deckhand's bundled extension, loaded first, owns
	// the name in a chat's TUI); a job does not (that extension registers nothing there)
	cro := PI_READONLY_CHAT_ARGS
	testing.expect(t, slice.equal(cro[:], []string{"--tools", "read,grep,find,ls,desk_show", "--exclude-tools", "mcp__*", "--no-mcp"}), "a read-only chat: pi's read tools and desk_show")

	state.settings.chats_readonly = true
	testing.expect(t, slice.equal(chat_args(chat.id), cro[:]), "a chat while chats are read-only: the allowlist")
	testing.expect(t, len(chat_args(proj.id)) == 0, "a project's pi: never")
	state.settings.chats_readonly = false
	testing.expect(t, len(chat_args(chat.id)) == 0, "a chat, read-only off: full pi")

	// a read-only job's argv carries the same flags, a full one none of them
	argv := job_argv("/bin/pi", "/s", "uuid", "", "", "/pre.md", "x", .Read)
	found := false
	for i := 0; i + len(ro) <= len(argv); i += 1 {
		if slice.equal(argv[i:i + len(ro)], ro[:]) do found = true
	}
	testing.expectf(t, found, "a read job: PI_READONLY_ARGS: %v", argv)
	for a in job_argv("/bin/pi", "/s", "uuid", "", "", "/pre.md", "x", .Full) do testing.expect(t, a != "--tools" && a != "--no-mcp", "a full job: pi's own tools")
}

// pi before 1.0.4 lacks --no-mcp and `*` patterns (and before 0.68, --tools covered built-in
// tools only): a known older pi never starts a read-only chat; an unknown version may.
@(test)
chat_readonly_needs_pi_1_0_4 :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved_projects, saved_ro, saved_v := state.projects, state.settings.chats_readonly, state.reload.pi_version
	defer {
		delete(state.projects)
		state.projects, state.settings.chats_readonly, state.reload.pi_version = saved_projects, saved_ro, saved_v
	}
	state.projects = {}
	chat := Project{id = new_id(), cwd = "/nonexistent/pd-chat-ro/Chats", group = .Chats}
	append(&state.projects, chat)
	for c in ([][2]string{{"", ""}, {"dev", ""}, {"1.0.4", ""}, {"1.5.0", ""}, {"2.0.0", ""}, {"1.0.3", "x"}, {"0.68.0", "x"}, {"0.60.1", "x"}, {"1.0.4-beta.1", "x"}}) {
		state.reload.pi_version = c[0]
		testing.expectf(t, pi_readonly_too_old() == (c[1] != ""), "pi %q", c[0])
	}
	state.settings.chats_readonly = true
	state.reload.pi_version = "1.0.3"
	open_before := len(state.open_sessions)
	r := run_command(New_Chat{project_id = chat.id}, Caller{kind = .UI})
	testing.expectf(t, !r.ok && r.error == PI_READONLY_CHAT_TOO_OLD, "refused: %v", r)
	testing.expect(t, strings.contains(PI_READONLY_CHAT_TOO_OLD, "update pi or turn off read-only chats"))
	testing.expect_value(t, len(state.open_sessions), open_before)
}
