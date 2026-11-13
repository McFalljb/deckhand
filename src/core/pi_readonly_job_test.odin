package core

// A read-only job (`access: read`) is enforced by pi itself, not only by pi-kit: its argv ends
// with pi's tool allowlist (PI_READONLY_ARGS), and a known pi too old for those flags never runs it.

import "base:runtime"
import "core:slice"
import "core:testing"

@(test)
pi_readonly_job_args :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	ro := PI_READONLY_ARGS
	testing.expect(t, slice.equal(ro[:], []string{"--tools", "read,grep,find,ls", "--exclude-tools", "mcp__*", "--no-mcp"}), "pi's read tools only, no bash, no MCP tools of any source")
	// a read-only job's argv carries the flags, a full one none of them
	argv := job_argv("/bin/pi", "/s", "uuid", "", "", "/pre.md", "x", .Read)
	found := false
	for i := 0; i + len(ro) <= len(argv); i += 1 {
		if slice.equal(argv[i:i + len(ro)], ro[:]) do found = true
	}
	testing.expectf(t, found, "a read job: PI_READONLY_ARGS: %v", argv)
	for a in job_argv("/bin/pi", "/s", "uuid", "", "", "/pre.md", "x", .Full) do testing.expect(t, a != "--tools" && a != "--no-mcp", "a full job: pi's own tools")
}

// pi before 1.0.4 lacks --no-mcp and `*` patterns (and before 0.68, --tools covered built-in
// tools only): a known older pi never runs a read-only job; an unknown version may.
@(test)
pi_readonly_needs_pi_1_0_4 :: proc(t: ^testing.T) {
	saved_v := state.reload.pi_version
	defer state.reload.pi_version = saved_v
	for c in ([][2]string{{"", ""}, {"dev", ""}, {"1.0.4", ""}, {"1.5.0", ""}, {"2.0.0", ""}, {"1.0.3", "x"}, {"0.68.0", "x"}, {"0.60.1", "x"}, {"1.0.4-beta.1", "x"}}) {
		state.reload.pi_version = c[0]
		testing.expectf(t, pi_readonly_too_old() == (c[1] != ""), "pi %q", c[0])
	}
}
