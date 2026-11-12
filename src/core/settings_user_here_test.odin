package core

import "base:runtime"
import "core:testing"

// The settings that bound what agents and other machines may do here are this Mac's user's only
// (User_Here): Allow other machines to connect, Machines over SSH, the pi extensions (guardrails),
// Claude's skip-permissions default and read-only chats. A machine viewing this Mac (a hub's ui)
// is refused as an agent, a script or a pi tab is; the user at this Mac still changes them, and
// the two that ask first ask this Mac's user.
@(test)
settings_user_here_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	suh_reset()
	defer suh_reset()
	cmds := []Command {
		Set_Machines_Reachable{on = true},
		Set_Remote_Machines{on = true},
		Set_Pi_Extension{name = "guardrails", on = false},
		Set_Claude_Default_Flags{skip_permissions = true},
		Set_Chats_Readonly{on = true},
	}
	not :: "not allowed for this caller"
	for cmd in cmds {
		name := command_type(cmd)
		spec := command_spec(name)
		testing.expectf(t, spec != nil && spec.who == .User_Here, "%s is this Mac's user's only", name)
		for c in ([]Caller{{kind = .UI, hub = true}, {kind = .Control, hub = true}, {kind = .Control}, {kind = .Script}, {kind = .Panel, tab_id = 1}}) {
			testing.expectf(t, run_command(cmd, c).error == not, "%s refused for %v", name, c)
		}
		testing.expectf(t, caller_may({kind = .UI}, cmd), "%s: the user at this Mac may", name)
		testing.expectf(t, caller_may({kind = .Internal}, cmd), "%s: a saved choice coming back", name)
	}
	testing.expect(t, !state.settings.machines_reachable && !state.settings.remote_machines, "nothing changed")
	testing.expect(t, !state.settings.claude_skip_permissions && !state.settings.chats_readonly, "nothing changed")
	testing.expect_value(t, len(state.pending_confirmations), 0)
	// the user at this Mac: the plain ones apply, the two that ask first ask here
	testing.expect(t, run_command(Set_Remote_Machines{on = true}, {kind = .UI}).ok && state.settings.remote_machines)
	testing.expect(t, run_command(Set_Chats_Readonly{on = true}, {kind = .UI}).ok && state.settings.chats_readonly)
	for cmd in ([]Command{Set_Machines_Reachable{on = true}, Set_Claude_Default_Flags{skip_permissions = true}}) {
		r := run_command(cmd, {kind = .UI})
		testing.expectf(t, r.error == "needs_confirmation" && r.confirm_token != "", "%s asks this Mac's user: %v", command_type(cmd), r.error)
	}
}

@(private = "file")
suh_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	core_detach_window()
}
