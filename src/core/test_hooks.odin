package core

// Test and development knobs, compiled out of release builds (docs/plans/background-core.md §5.3,
// "A genuine binary under attacker config"): a signed Deckhand passes every identity check whatever
// its environment, so a release build must not be steerable by it. scripts/release.sh builds with
// -define:DECKHAND_TEST_HOOKS=false (DECKHAND_RELEASE=1 ./build.sh) and then checks the binaries
// for every name below, and for any DECKHAND_ name not in its ALLOWED list (scripts/check-release-build.sh):
// none may be left; scripts/check-env-reads.py (run by it and by ./build.sh test) refuses any other
// environment read of a name not on its list, or not a literal. The CEF shim's knobs (DECKHAND_CEF_SPARE, DECKHAND_CEF_NETLOG) are compiled out
// with -DDH_RELEASE=1 (build.sh).
//
// With the hooks off:
//   - every hook_env() is "" (test mode never starts: no DECKHAND_SCRIPT), and the names
//     themselves are not in the binary (HOOK_ENV is compiled only with the hooks on);
//   - the data and runtime dirs are the fixed ones (no DECKHAND_DATA_DIR, DECKHAND_RUNTIME_DIR), under
//     the account's home from the user database, not $HOME (platform.odin data_home);
//   - `--print-token` is not accepted (Settings › Copy a control token mints one, the user's).
// Test and development builds (./build.sh, ./build.sh test, every scene) keep them.
//
// Not hooks, so kept (each in check-release-build.sh's ALLOWED, with why): DECKHAND_SOCKET and
// DECKHAND_TOKEN (what Deckhand gives its tabs, read by `deckhand --ctl`) and the other names it
// sets in its tabs' and jobs' environments, DECKHAND_GUI_LAUNCH and DECKHAND_CEF_SHARED_TEXTURE (the
// user's workarounds, docs/DEVELOPING.md, docs/BROWSER.md). None steers who Deckhand trusts or
// what it runs.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

TEST_HOOKS :: #config(DECKHAND_TEST_HOOKS, true)

// Test mode runs a script (autotest.odin, DECKHAND_SCRIPT): the core logs more, never touches the
// user's Trash or Finder, and starts the holder directly.
autotest_active: bool

Hook :: enum u8 {
	Script, // test mode: the script to run (autotest.odin)
	Script_Fail_Fast,
	Script_Step,
	Wait_Audit,
	Quiet,
	Scale,
	First_Run,
	Data_Dir, // a data dir instead of the fixed one (platform.odin)
	Runtime_Dir, // a runtime dir instead of the fixed one (socket_posix.odin)
	Cmd, // what a pi tab runs
	Real_Pi,
	Claude_Cmd,
	Claude_Bin,
	Claude_Plugin,
	Pi_Integration,
	Pi_Package,
	Install_Cmd,
	Gpu_Lag_Ms,
	Holder_Direct,
	Holder_Rev, // the bundled holder's rev as the app sees it (holder_upgrade_wanted): a scene's upgrade at attach
	Temp_Roots,
	Debug_Browser,
	Cef_Offline,
	Log_Commands,
	Path_Dirs,
	Update_Url, // the updater's fixtures (update.odin; with -define:DECKHAND_UPDATE_TEST=true only)
	Update_Download,
	Update_Version,
	Update_App,
	Proto_Log, // the window's link prints its frames (client.odin)
	Separate_Core, // 1: the window runs its core as another process (deckhand-core serve); 0: in process (main.odin)
	Core_Handover, // self: the window hands the core it finds over to a new one of the same binary at its attach (client_core.odin)
}

when TEST_HOOKS {
	// scripts/check-release-build.sh reads the names from here: one `= "DECKHAND_…"` per line
	HOOK_ENV := [Hook]string {
		.Script           = "DECKHAND_SCRIPT",
		.Script_Fail_Fast = "DECKHAND_SCRIPT_FAIL_FAST",
		.Script_Step      = "DECKHAND_SCRIPT_STEP",
		.Wait_Audit       = "DECKHAND_WAIT_AUDIT",
		.Quiet            = "DECKHAND_QUIET",
		.Scale            = "DECKHAND_SCALE",
		.First_Run        = "DECKHAND_FIRST_RUN",
		.Data_Dir         = "DECKHAND_DATA_DIR",
		.Runtime_Dir      = "DECKHAND_RUNTIME_DIR",
		.Cmd              = "DECKHAND_CMD",
		.Real_Pi          = "DECKHAND_REAL_PI",
		.Claude_Cmd       = "DECKHAND_CLAUDE_CMD",
		.Claude_Bin       = "DECKHAND_CLAUDE_BIN",
		.Claude_Plugin    = "DECKHAND_CLAUDE_PLUGIN",
		.Pi_Integration   = "DECKHAND_PI_INTEGRATION",
		.Pi_Package       = "DECKHAND_PI_PACKAGE",
		.Install_Cmd      = "DECKHAND_INSTALL_CMD",
		.Gpu_Lag_Ms       = "DECKHAND_TEST_GPU_LAG_MS",
		.Holder_Direct    = "DECKHAND_HOLDER_DIRECT",
		.Holder_Rev       = "DECKHAND_HOLDER_REV",
		.Temp_Roots       = "DECKHAND_TEMP_ROOTS",
		.Debug_Browser    = "DECKHAND_DEBUG_BROWSER",
		.Cef_Offline      = "DECKHAND_CEF_OFFLINE",
		.Log_Commands     = "DECKHAND_LOG_COMMANDS",
		.Path_Dirs        = "DECKHAND_PATH_DIRS",
		.Update_Url       = "DECKHAND_UPDATE_URL",
		.Update_Download  = "DECKHAND_UPDATE_DOWNLOAD",
		.Update_Version   = "DECKHAND_UPDATE_VERSION",
		.Update_App       = "DECKHAND_UPDATE_APP",
		.Proto_Log        = "DECKHAND_PROTO_LOG",
		.Separate_Core    = "DECKHAND_SEPARATE_CORE",
		.Core_Handover    = "DECKHAND_CORE_HANDOVER",
	}
}

// Which hooks were read under their old PI_DESK_ name this run (one warning each), and the last
// warning's text (tests).
hook_warned: [Hook]bool
hook_last_warning: string

// A hook's value ("" when unset, and always in a release build).
hook_env :: proc(h: Hook, allocator := context.temp_allocator) -> string {
	v, _ := hook_lookup(h, allocator)
	return v
}

// A hook's value and whether it is set at all (an empty value counts: DECKHAND_PATH_DIRS="").
// The rename (0.1.7): when DECKHAND_X is unset, its old name PI_DESK_X counts, with a one-line
// warning (once per hook) naming the new one, so a dev launcher or a forge script that still
// sets PI_DESK_DATA_DIR never opens the user's real data dir. Not refused: forge sets both while
// it moves over. Release builds have neither name (the hooks are compiled out).
hook_lookup :: proc(h: Hook, allocator := context.temp_allocator) -> (string, bool) {
	when TEST_HOOKS {
		name := HOOK_ENV[h]
		if v, ok := os.lookup_env(name, allocator); ok do return v, true // env-read-ok: hook_lookup itself
		old := strings.concatenate({LEGACY_ENV_PREFIX, name[len("DECKHAND_"):]}, context.temp_allocator)
		v, ok := os.lookup_env(old, allocator) // env-read-ok: a hook's old name, built from HOOK_ENV
		if ok && !hook_warned[h] {
			hook_warned[h] = true
			hook_last_warning = fmt.aprintf("Deckhand: %s is the old name of %s; set %s instead (the old name stops working in 0.2.0)", old, name, name, allocator = runtime.heap_allocator())
			fmt.eprintln(hook_last_warning)
		}
		return v, ok
	} else {
		return "", false
	}
}
