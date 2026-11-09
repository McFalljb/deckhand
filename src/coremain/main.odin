// deckhand-core-serve (in Deckhand Core.app beside deckhand-core, the session holder;
// docs/plans/background-core.md §7.1, §10.3 M4-C): the core, headless.
//
//   deckhand-core-serve serve --run DIR --data DIR [--ready PATH]   the core (serve.odin)
//   deckhand-core-serve __detach serve ...                          launchd job entry for serve
//   deckhand-core-serve check                       this core's facts, one JSON line (core_versions.odin)
//   deckhand-core-serve install --data DIR          this Core.app into DIR/core/<v>/, made current;
//                                                   prints the installed serve binary
//   deckhand-core-serve launch --run DIR --data DIR  starts this binary's core through the launchd
//                                                   launcher, then exits (the holder's supervisor)
//   deckhand-core-serve connect [--from NAME]       another machine's hub link, over its ssh: the
//                                                   hub hello on this machine's core.sock, then
//                                                   stdio <-> the socket (connect.odin)
//   deckhand-core-serve linger [--enable]           Linux: this user's systemd linger, on|off|unknown;
//                                                   --enable (the user said yes) asks logind for it,
//                                                   no password prompt, no sudo (platform_linux.odin)
//
// The plan has one binary (deckhand-core gaining `serve`). Linking the core package and the
// holder's `hold` into one executable crashes Odin's LLVM backend at -o:speed (an assertion in
// llvm_backend_utility.cpp, `llvm_sz == llvm_dz` i32 i16; dev-2026-09), so serve is its own
// executable, signed with the same identifier; the holder binary is unchanged. One binary again
// once the compiler takes it. Only ready_handshake is used from src/holder.
// Obj-C shims are allowed here (core_macos.m), never in src/core.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

import "../core"

main :: proc() {
	if len(os.args) >= 2 && os.args[1] == "serve" do os.exit(serve_main(os.args[2:]))
	if len(os.args) >= 3 && os.args[1] == "__detach" && os.args[2] == "serve" do os.exit(detach_serve(os.args[3:]))
	if len(os.args) == 2 && os.args[1] == "check" {
		fmt.println(core.core_check_json())
		os.exit(0)
	}
	if len(os.args) == 4 && os.args[1] == "install" && os.args[2] == "--data" do os.exit(install_main(os.args[3]))
	if len(os.args) == 6 && os.args[1] == "launch" && os.args[2] == "--run" && os.args[4] == "--data" do os.exit(launch_main(os.args[3], os.args[5]))
	if len(os.args) >= 2 && os.args[1] == "connect" do os.exit(connect_main(os.args[2:]))
	when ODIN_OS == .Linux do if len(os.args) >= 2 && os.args[1] == "linger" do os.exit(linger_main(os.args[2:]))
	fmt.eprintln(SERVE_USAGE)
	os.exit(2)
}

// `install --data DIR`: the Core.app this binary is in, installed and made current. On Linux
// (no Core.app): this binary, then the systemd user unit and the linger check
// (core.core_install_linux); what the user should know goes to stderr.
install_main :: proc(data: string) -> int {
	exe := core.executable_path()
	when ODIN_OS == .Linux {
		lserve, note, lok := core.core_install_linux(exe, data)
		if note != "" do fmt.eprintln("deckhand-core-serve install:", note)
		if !lok do return 1
		fmt.println(lserve)
		return 0
	}
	app := core.holder_bundle_of(fmt.tprintf("%s/%s", filepath.dir(exe), core.HOLDER_BIN))
	if app == "" {
		fmt.eprintln("deckhand-core-serve install: not inside a Deckhand Core.app:", exe)
		return 2
	}
	serve, ok, why := core.core_install_app(app, data)
	if !ok {
		fmt.eprintln("deckhand-core-serve install:", why)
		return 1
	}
	fmt.println(serve)
	return 0
}

// `launch --run DIR --data DIR`: the supervisor's relaunch (src/holder supervisor.odin). The core is
// started as the window starts one (core.core_launch: a launchd job, or directly in test mode), so
// it never descends from the holder.
launch_main :: proc(run, data: string) -> int {
	when core.TEST_HOOKS do core.autotest_active = core.hook_env(.Script) != ""
	exe := core.executable_path()
	if exe == "" do return 1
	_, ok, why := core.core_launch(exe, run, data)
	if !ok {
		fmt.eprintln("deckhand-core-serve launch:", why)
		return 1
	}
	return 0
}
