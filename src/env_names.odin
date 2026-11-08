package main

// The environment names Deckhand sets for its tabs, jobs and control callers, and their old
// pi-desk names (the rename, 0.1.7). Until 0.2.0 (or 3 releases after 0.1.7, whichever is later)
// every DECKHAND_X below is set with its PI_DESK_X twin, so tools that read the old name keep
// working (forge's engine reads PI_DESK_SOCKET and PI_DESK_TOKEN). Readers prefer DECKHAND_X and
// fall back to PI_DESK_X for good: a session held across an update (keep_sessions) keeps the
// environment it started with. pi tabs and Atlas never get the old names (pi-kit's desk
// extensions switch on with PI_DESK_SOCKET and PI_DESK_TOKEN: pi_integration.odin).

import "core:strings"

LEGACY_ENV_PREFIX :: "PI_DESK_"

// What Deckhand sets (suffixes after DECKHAND_ / PI_DESK_). The scrubs drop exactly these
// (both names) from what a tab inherits, never every DECKHAND_ variable: the user's own
// DECKHAND_SIGN_IDENTITY, DECKHAND_RELEASE and the like reach a shell tab.
DESK_SET_ENV := [?]string {
	"SOCKET", "TOKEN", "CONTROL_TOKEN", "SHOTS_DIR", // every tab kind's transport
	"CLAUDE_TOKEN", "CLAUDE_TAB", "CLAUDE_READONLY", "CLAUDE_ACCOUNT", "CLI", // Claude tabs
	"APP", // app tabs
	"JOB", "RUN", "RUN_DIR", "SCHEDULED_AT", // job runs
}

// The PI_DESK_ twins set beside the new names (not CONTROL_TOKEN: only pi's Atlas gets one).
DESK_LEGACY_SET := [?]string{"SOCKET", "TOKEN", "CLAUDE_TOKEN", "CLAUDE_TAB", "CLAUDE_READONLY", "CLAUDE_ACCOUNT", "CLI", "SHOTS_DIR", "APP", "JOB", "RUN", "RUN_DIR", "SCHEDULED_AT"}

// The user's documented workarounds, read under both names (DECKHAND_ first).
DESK_WORKAROUND_ENV := [?]string{"GUI_LAUNCH", "CEF_SHARED_TEXTURE"}

// env with every "DECKHAND_X=v" of DESK_LEGACY_SET followed by its "PI_DESK_X=v" (temp).
env_with_legacy :: proc(env: []string) -> []string {
	out := make([dynamic]string, 0, 2 * len(env), context.temp_allocator)
	for e in env {
		append(&out, e)
		eq := strings.index_byte(e, '=')
		if eq < 0 || !strings.has_prefix(e, "DECKHAND_") do continue
		suffix := e[len("DECKHAND_"):eq]
		for s in DESK_LEGACY_SET do if s == suffix {
			append(&out, strings.concatenate({LEGACY_ENV_PREFIX, e[len("DECKHAND_"):]}, context.temp_allocator))
			break
		}
	}
	return out[:]
}

// The name of a "K=V" entry (all of it without '=').
env_key :: proc(e: string) -> string {
	eq := strings.index_byte(e, '=')
	return eq < 0 ? e : e[:eq]
}

// k is one Deckhand sets for a tab, job or control caller, or a workaround, under either name.
env_desk_set :: proc(k: string) -> bool {
	suffix: string
	switch {
	case strings.has_prefix(k, "DECKHAND_"): suffix = k[len("DECKHAND_"):]
	case strings.has_prefix(k, LEGACY_ENV_PREFIX): suffix = k[len(LEGACY_ENV_PREFIX):]
	case: return false
	}
	for s in DESK_SET_ENV do if s == suffix do return true
	for s in DESK_WORKAROUND_ENV do if s == suffix do return true
	return false
}

// k is Deckhand's own: what env_desk_set says, any old PI_DESK_ name, or a test hook (in builds
// that have them). Never taken from the login shell (login_env.odin) nor passed to an app tab.
env_desk_owned :: proc(k: string) -> bool {
	if strings.has_prefix(k, LEGACY_ENV_PREFIX) || env_desk_set(k) do return true
	when TEST_HOOKS {
		for h in HOOK_ENV do if h == k do return true
	}
	return false
}
