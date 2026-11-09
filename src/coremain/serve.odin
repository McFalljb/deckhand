package main

// `deckhand-core serve` (docs/plans/background-core.md §10.3 M4-C): the core package under a
// headless main. It takes core.lock and instance.lock, owns core.sock (the control socket, and
// the window's door: run/window.token, window_sock.odin), adopts the session holder, restores
// the workspace and serves, with or without a window. Job runs are its children.
//
// The loop is poll(2) on a self-pipe (platform.wake from any thread, a reader's first output:
// core.output_wake) and the window's socket, with the core timer's period as the timeout. Each
// turn: what run_later queued, the windows that said hello, a core tick, the socket's writes. A
// tick that left terminal output unparsed (READ_BUDGET) runs again at once.
//
// Until M4-D: ⌘Q closes the window and this core runs on; Quit Deckhand and Stop All Sessions
// (Quit{stop_sessions}) ends it. Notifications go through the window (window.request notify);
// with none attached there is none (M4-D gives the core its own banners). Updates, the first-run
// sheet and app tabs are the in-process window's only for now.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "../core"
import "../holder"

foreign import shim "../../build/dh_coremain.a"
foreign import foundation "system:Foundation.framework"
@(default_calling_convention = "c")
foreign shim {
	dh_core_activity :: proc(on: c.int) ---
	dh_core_trash :: proc(path: cstring) -> c.int ---
}
_ :: foundation

@(private = "file")
loop: struct {
	wake_r, wake_w: posix.FD,
	woken:          bool, // atomic: a wake since the last turn
	later:          [dynamic]proc(),
	every:          time.Duration, // the core timer's period (0: none)
	fire:           proc(),
	next_fire:      time.Tick,
	quit:           bool,
}

SERVE_USAGE :: "usage: deckhand-core-serve serve --run DIR --data DIR [--ready PATH]"

serve_main :: proc(args: []string) -> int {
	run, data, ready: string
	for i := 0; i < len(args); i += 1 {
		if i + 1 >= len(args) {
			fmt.eprintln(SERVE_USAGE)
			return 2
		}
		switch args[i] {
		case "--run":   run = args[i + 1]
		case "--data":  data = args[i + 1]
		case "--ready": ready = args[i + 1]
		case:
			fmt.eprintln(SERVE_USAGE)
			return 2
		}
		i += 1
	}
	if run == "" || data == "" {
		fmt.eprintln(SERVE_USAGE)
		return 2
	}
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	// SIGTERM, SIGINT: a clean stop (the handover keeps the held sessions), as Quit does
	posix.signal(.SIGTERM, serve_on_signal)
	posix.signal(.SIGINT, serve_on_signal)
	// launched through launchd: the launcher's environment (it carries the window's settings)
	if ready != "" {
		if _, ok := holder.ready_handshake(ready); !ok do return 1
	}
	core.persist.launch = time.tick_now()
	core.app_context = context
	when core.TEST_HOOKS do core.autotest_active = core.hook_env(.Script) != ""
	if !serve_platform() do return 1
	core.home_root = strings.clone(data)
	if why := core.instance_guard(core.home_root, !core.autotest_active || core.hook_env(.Runtime_Dir) != ""); why != "" {
		fmt.eprintln("deckhand-core serve:", why)
		return 3
	}
	fmt.eprintfln("deckhand-core serve: pid %d, data %s, run %s", posix.getpid(), data, run)
	core.event_log_open(core.home_root)
	{
		y, m, d := time.date(time.now())
		core.agent_prompt_migrate(fmt.tprintf("%04d-%02d-%02d", y, int(m), d))
		core.agent_guide_install()
	}
	files := !core.autotest_active || core.hook_env(.Data_Dir) != "" // test mode: only with a data dir of its own
	if files do core.titles_load(core.data_dir(context.temp_allocator))
	core.claude_accounts_refresh()
	core.rescan_now(claude = false)
	if !core.socket_start() {
		fmt.eprintln("deckhand-core serve: cannot listen on core.sock")
		return 1
	}
	// test mode: a control token in the core's log, for the scenes' --ctl (never in a release build)
	when core.TEST_HOOKS {
		if core.autotest_active {
			fmt.printf("export DECKHAND_SOCKET='%s' DECKHAND_TOKEN='%s'\n", core.socket_path(), core.socket_mint_token({kind = .Control}, context.temp_allocator))
			os.flush(os.stdout)
		}
	}
	if !core.window_token_publish(run) {
		fmt.eprintln("deckhand-core serve: cannot write", run, "/", core.WINDOW_TOKEN_FILE)
		return 1
	}
	core.state.settings.keep_sessions = core.keep_sessions_default()
	if files {
		core.persist_init(core.data_dir(context.temp_allocator))
		core.claude_disk_launching = true
		core.persist_load(false)
		core.claude_disk_launching = false
	}
	core.holder_adopt_all()
	core.harness_no_sudo_sweep(at_quit = false)
	if core.claude_startup_rescan_due() do core.run_command(core.Rescan{}, {kind = .Internal})
	if files && !core.setup_due() do core.chats_instructions_ensure(core.date_stamp())
	core.core_loop_start()
	serve_loop()
	serve_stop()
	return 0
}

// The platform a headless core gives the core package (platform.odin).
@(private = "file")
serve_platform :: proc() -> bool {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK do return false
	for fd in fds {
		posix.fcntl(fd, .SETFL, posix.fcntl(fd, .GETFL) | posix.O_NONBLOCK)
		posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	}
	loop.wake_r, loop.wake_w = fds[0], fds[1]
	loop.later = make([dynamic]proc(), runtime.heap_allocator())
	core.output_wake_on = true
	core.platform = {
		quit = proc() {
			core.app_quitting = true
			loop.quit = true
		},
		wake = proc() {
			if sync.atomic_exchange(&loop.woken, true) do return // one byte per turn is enough
			b := [1]u8{1}
			posix.write(loop.wake_w, &b[0], 1)
		},
		run_later = proc(p: proc()) {append(&loop.later, p)},
		notify = proc(title, body: string) {
			if core.autotest_active do fmt.println("[autotest] notify:", title, "-", body)
			core.window_notify(title, body)
		},
		trash = proc(path: string) -> bool {return dh_core_trash(strings.clone_to_cstring(path, context.temp_allocator)) == 1},
		activity = proc(on: bool) {dh_core_activity(on ? 1 : 0)},
		core_timer = proc(every: time.Duration, fire: proc()) {
			loop.every, loop.fire = every, fire
			loop.next_fire = time.tick_add(time.tick_now(), every)
		},
	}
	return true
}

@(private = "file")
serve_loop :: proc() {
	pfd: [2]posix.pollfd
	for !loop.quit {
		// how long to sleep: until the timer, or not at all while the last tick left output to parse
		timeout := -1
		if loop.every > 0 do timeout = max(0, int(time.duration_milliseconds(time.tick_diff(time.tick_now(), loop.next_fire))) + 1)
		before := terms_bytes_in()
		pfd[0] = {fd = loop.wake_r, events = {.IN}}
		n := 1
		if fd, out := core.window_link_fd(); fd >= 0 {
			pfd[1] = {fd = fd, events = out ? {.IN, .OUT} : {.IN}}
			n = 2
		}
		if loop_again do timeout = 0
		posix.poll(&pfd[0], posix.nfds_t(n), c.int(timeout))
		drain: [64]u8
		for posix.read(loop.wake_r, &drain[0], len(drain)) > 0 {}
		sync.atomic_store(&loop.woken, false)
		later := loop.later
		loop.later = make([dynamic]proc(), runtime.heap_allocator())
		for p in later do p()
		delete(later)
		core.window_door_tick()
		now := time.tick_now()
		if loop.every > 0 && time.tick_diff(loop.next_fire, now) >= 0 {
			loop.next_fire = time.tick_add(now, loop.every)
			if loop.fire != nil do loop.fire() // core_timer_fire: a tick (no frames here)
		} else do core.core_tick()
		core.window_link_io()
		loop_again = core.output_backlog() && terms_bytes_in() != before
		free_all(context.temp_allocator)
	}
}

@(private = "file")
loop_again: bool

@(private = "file")
serve_on_signal :: proc "c" (sig: posix.Signal) {
	loop.quit = true
	b := [1]u8{1}
	posix.write(loop.wake_w, &b[0], 1)
}

// Every terminal's bytes parsed so far: a tick that parsed nothing makes no progress to repeat.
@(private = "file")
terms_bytes_in :: proc() -> int {
	n := 0
	for _, t in core.terms do n += t.bytes_in
	return n
}

// The end (Quit, or a signal): as the in-process window's quit and cleanup do.
@(private = "file")
serve_stop :: proc() {
	core.core_loop_stop()
	core.window_door_stop() // the window's link and any waiting: they are not srv.conns
	if core.app_stop_sessions do core.holder_shutdown()
	else do core.holder_handover()
	core.persist_quit()
	core.login_env_kill_probe()
	core.harness_no_sudo_sweep(at_quit = true)
	core.titles_save()
	core.socket_stop()
	core.jobs_shutdown()
	core.close_all()
	core.holder_client_stop()
	core.comments_shutdown()
	dh_core_activity(0)
	if core.autotest_active do fmt.println("[autotest] core: stopped")
}

// `deckhand-core __detach serve ARGS...` (the launchd job, launchd_darwin.odin): fork, the parent
// exits, the child calls setsid and execs `deckhand-core serve ARGS...` (a relative --ready made
// absolute, as the holder's detach does: the job's working dir is the launcher's temp dir).
detach_serve :: proc(args: []string) -> int {
	self := os.args[0]
	if !strings.has_prefix(self, "/") {
		fmt.eprintln("deckhand-core __detach serve: not started by its absolute path:", self)
		return 2
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	argv := make([dynamic]cstring, context.temp_allocator)
	append(&argv, strings.clone_to_cstring(self, context.temp_allocator), "serve")
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if a == "--ready" && i + 1 < len(args) && !strings.has_prefix(args[i + 1], "/") {
			append(&argv, "--ready", strings.clone_to_cstring(fmt.tprintf("%s/%s", strings.trim_right(cwd, "/"), args[i + 1]), context.temp_allocator))
			i += 1
			continue
		}
		append(&argv, strings.clone_to_cstring(a, context.temp_allocator))
	}
	append(&argv, nil)
	pid := posix.fork()
	if pid < 0 do return 1
	if pid > 0 do return 0
	posix.setsid()
	posix.chdir("/")
	posix.execv(argv[0], raw_data(argv[:]))
	posix._exit(127)
}
