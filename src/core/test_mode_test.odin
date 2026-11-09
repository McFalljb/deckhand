package core

// Test mode (DECKHAND_SCRIPT) fails closed: a real `pi` or `claude` never starts unless the scene
// replaces it (DECKHAND_CMD, DECKHAND_CLAUDE_CMD) or opts in to the real pi (DECKHAND_REAL_PI=1).
// Every launch path goes through pi_tab_cmd / claude_tab_cmd (tabs, restore, Atlas, dead-tab
// restarts) or job_pi_path (jobs' runner).

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
Saved_Env :: struct {
	k, v: string,
	had:  bool,
}

@(private = "file")
save_env :: proc(keys: ..string) -> []Saved_Env {
	out := make([]Saved_Env, len(keys), runtime.heap_allocator())
	for k, i in keys {
		v, ok := os.lookup_env(k, runtime.heap_allocator())
		out[i] = {k, v, ok}
	}
	return out
}

@(private = "file")
restore_env :: proc(s: []Saved_Env) {
	for e in s {
		if e.had do os.set_env(e.k, e.v)
		else do os.unset_env(e.k)
	}
}

@(test)
test_mode_refuses_real_binaries :: proc(t: ^testing.T) {
	saved := save_env("DECKHAND_SCRIPT", "DECKHAND_CMD", "DECKHAND_CLAUDE_CMD", "DECKHAND_REAL_PI")
	defer restore_env(saved)
	os.unset_env("DECKHAND_CMD")
	os.unset_env("DECKHAND_CLAUDE_CMD")
	os.unset_env("DECKHAND_REAL_PI")
	// not test mode: the real commands
	os.unset_env("DECKHAND_SCRIPT")
	testing.expect_value(t, pi_tab_cmd(), PI_TAB_CMD)
	testing.expect_value(t, claude_tab_cmd(), CLAUDE_TAB_CMD)
	// test mode without a stand-in: a refusal that exits 127, never `exec pi` / `exec claude`
	os.set_env("DECKHAND_SCRIPT", "tests/scripts/x.txt")
	testing.expect(t, strings.contains(pi_tab_cmd(), "refusing to run the real pi"), pi_tab_cmd())
	testing.expect(t, strings.contains(pi_tab_cmd(), "exit 127"))
	testing.expect(t, !strings.contains(pi_tab_cmd(), "exec pi"))
	testing.expect(t, strings.contains(claude_tab_cmd(), "refusing to run the real claude"), claude_tab_cmd())
	testing.expect(t, strings.contains(claude_tab_cmd(), "exit 127"))
	testing.expect(t, !strings.contains(claude_tab_cmd(), "exec claude"))
	// DECKHAND_REAL_PI=1: the real pi (real-pi scenes); claude has no such opt-in
	os.set_env("DECKHAND_REAL_PI", "1")
	testing.expect_value(t, pi_tab_cmd(), PI_TAB_CMD)
	testing.expect(t, strings.contains(claude_tab_cmd(), "refusing"))
	os.unset_env("DECKHAND_REAL_PI")
	// the stand-ins win
	os.set_env("DECKHAND_CMD", "echo pi")
	os.set_env("DECKHAND_CLAUDE_CMD", "echo claude")
	testing.expect_value(t, pi_tab_cmd(), "echo pi")
	testing.expect_value(t, claude_tab_cmd(), "echo claude")
	// jobs: no pi from PATH or pi's managed install in test mode; the pi_path setting (a scene's
	// fake) still runs
	os.unset_env("DECKHAND_CMD")
	keep := state.settings.pi_path
	defer state.settings.pi_path = keep
	state.settings.pi_path = ""
	testing.expect_value(t, job_pi_path(), "")
	state.settings.pi_path = "/fake/pi"
	testing.expect_value(t, job_pi_path(), "/fake/pi")
}
