package main

// Test and development knobs, compiled out of release builds (docs/plans/background-core.md §5.3,
// "A genuine binary under attacker config"): a signed Deckhand passes every identity check whatever
// its environment, so a release build must not be steerable by it. scripts/release.sh builds with
// -define:DECKHAND_TEST_HOOKS=false (DECKHAND_RELEASE=1 ./build.sh) and then checks the binaries
// for every name below, and for any PI_DESK_ name not in its ALLOWED list (scripts/check-release-build.sh):
// none may be left. The CEF shim's knobs (PI_DESK_CEF_SPARE, PI_DESK_CEF_NETLOG) are compiled out
// with -DPD_RELEASE=1 (build.sh).
//
// With the hooks off:
//   - every hook_env() is "" (test mode never starts: no PI_DESK_SCRIPT), and the names
//     themselves are not in the binary (HOOK_ENV is compiled only with the hooks on);
//   - the data and runtime dirs are the fixed ones (no PI_DESK_DATA_DIR, PI_DESK_RUNTIME_DIR);
//   - `--print-token` is not accepted (Settings › Copy a control token mints one, the user's).
// Test and development builds (./build.sh, ./build.sh test, every scene) keep them.
//
// Not hooks, so kept (each in check-release-build.sh's ALLOWED, with why): PI_DESK_SOCKET and
// PI_DESK_TOKEN (what Deckhand gives its tabs, read by `deckhand --ctl`) and the other names it
// sets in its tabs' and jobs' environments, PI_DESK_GUI_LAUNCH and PI_DESK_CEF_SHARED_TEXTURE (the
// user's workarounds, docs/DEVELOPING.md, docs/BROWSER.md). None steers who Deckhand trusts or
// what it runs.

import "core:os"

TEST_HOOKS :: #config(DECKHAND_TEST_HOOKS, true)

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
	Temp_Roots,
	Debug_Browser,
	Cef_Offline,
	Log_Commands,
	Path_Dirs,
	Update_Url, // the updater's fixtures (update.odin; with -define:PI_DESK_UPDATE_TEST=true only)
	Update_Download,
	Update_Version,
	Update_App,
}

when TEST_HOOKS {
	// scripts/check-release-build.sh reads the names from here: one `= "PI_DESK_…"` per line
	HOOK_ENV := [Hook]string {
		.Script           = "PI_DESK_SCRIPT",
		.Script_Fail_Fast = "PI_DESK_SCRIPT_FAIL_FAST",
		.Script_Step      = "PI_DESK_SCRIPT_STEP",
		.Wait_Audit       = "PI_DESK_WAIT_AUDIT",
		.Quiet            = "PI_DESK_QUIET",
		.Scale            = "PI_DESK_SCALE",
		.First_Run        = "PI_DESK_FIRST_RUN",
		.Data_Dir         = "PI_DESK_DATA_DIR",
		.Runtime_Dir      = "PI_DESK_RUNTIME_DIR",
		.Cmd              = "PI_DESK_CMD",
		.Real_Pi          = "PI_DESK_REAL_PI",
		.Claude_Cmd       = "PI_DESK_CLAUDE_CMD",
		.Claude_Bin       = "PI_DESK_CLAUDE_BIN",
		.Claude_Plugin    = "PI_DESK_CLAUDE_PLUGIN",
		.Pi_Integration   = "PI_DESK_PI_INTEGRATION",
		.Pi_Package       = "PI_DESK_PI_PACKAGE",
		.Install_Cmd      = "PI_DESK_INSTALL_CMD",
		.Gpu_Lag_Ms       = "PI_DESK_TEST_GPU_LAG_MS",
		.Holder_Direct    = "PI_DESK_HOLDER_DIRECT",
		.Temp_Roots       = "PI_DESK_TEMP_ROOTS",
		.Debug_Browser    = "PI_DESK_DEBUG_BROWSER",
		.Cef_Offline      = "PI_DESK_CEF_OFFLINE",
		.Log_Commands     = "PI_DESK_LOG_COMMANDS",
		.Path_Dirs        = "PI_DESK_PATH_DIRS",
		.Update_Url       = "PI_DESK_UPDATE_URL",
		.Update_Download  = "PI_DESK_UPDATE_DOWNLOAD",
		.Update_Version   = "PI_DESK_UPDATE_VERSION",
		.Update_App       = "PI_DESK_UPDATE_APP",
	}
}

// A hook's value ("" when unset, and always in a release build).
hook_env :: proc(h: Hook, allocator := context.temp_allocator) -> string {
	when TEST_HOOKS {
		return os.get_env(HOOK_ENV[h], allocator)
	} else {
		return ""
	}
}

// A hook's value and whether it is set at all (an empty value counts: PI_DESK_PATH_DIRS="").
hook_lookup :: proc(h: Hook, allocator := context.temp_allocator) -> (string, bool) {
	when TEST_HOOKS {
		return os.lookup_env(HOOK_ENV[h], allocator)
	} else {
		return "", false
	}
}
