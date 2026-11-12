package main

// Deckhand spike: a native window (sokol_app + sokol_gfx/gl) with a Clay
// sidebar of pi projects and sessions, and a terminal pane running pi's
// fullscreen TUI on our own PTY + libghostty-vt.
//
// Frame loop: read the PTY, then redraw only if something changed (PTY
// output, input, resize). Idle frames do no GPU work.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "core"
import cw "corewire"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"
import sg "../vendor/sokol-odin/sokol/gfx"
import sgl "../vendor/sokol-odin/sokol/gl"
import sglue "../vendor/sokol-odin/sokol/glue"
import slog "../vendor/sokol-odin/sokol/log"

OUTPUT_FRAME :: 15 * time.Millisecond

App :: struct {
	dpi:            f32,
	pending_start:  bool, // `deckhand DIR`: open a new chat once the pane has a size
	launch_project: u64, // its project (launch_project)
	pane:           [4]f32, // the focused pane's content rect x, y, w, h (framebuffer px)
	centre:         [4]f32, // the panes' area: every pane and divider of the session on screen (framebuffer px)
	redraw:         bool,
	drag_tab:       u64, // the tab on screen when drags were last checked (drags_follow_focus)
	frames_drawn:   u64,
	last_draw:      time.Tick,
	pointer:        [2]f32,
	ready:          bool, // init done: the inbox may be drained
	wakes:          u64, // platform wakes that ran
	font_theme:     core.Theme_Id, // the look the fonts were opened for
	font_size:      core.Text_Size, // and the text size
	// clicks: count of the current multi-click (1, 2, 3, ...)
	clicks:         int,
	last_click:     time.Tick,
	last_click_at:  [2]f32,
	field_drag:     bool, // a press in the focused field: moves extend its selection
	key_in_widget:  bool, // the last KEY_DOWN went to a widget
	key_taken:      bool, // the last KEY_DOWN was the chrome's: drop its CHAR/KEY_UP
	window_active:  bool, // the window has the keyboard (sokol FOCUSED/UNFOCUSED)
	last_frame_at:  time.Tick, // a separate core: the last frame's start (the timer reads the core only between frames)
	closing:        bool, // a separate core: the window is closing, the core runs on (quit_route)
	close_asked:    time.Tick, // a separate core: app_request_quit asked sokol to close the window ({} = not, or it did)
	window_title:   string,
}

// An input method's composition (dead key, IME), shown at the caret of the
// focused field or the terminal cursor until committed. UI state.
Ime :: struct {
	marked:     string, // "" = none (heap)
	caret:      int, // byte offset in marked
	caret_rect: [4]f32, // last drawn caret (framebuffer px): the candidate window goes under it
	os_cancels: int, // compositions dropped in the platform's input method too (tests)
}
ime: Ime

app: App

init :: proc "c" () {
	context = core.app_context
	sg.setup({environment = sglue.environment(), logger = {func = slog.func}})
	sgl.setup({max_vertices = 1 << 20, max_commands = 1 << 14, logger = {func = slog.func}})
	app.dpi = sapp.dpi_scale()
	font_config = theme_font_config(theme())
	app.font_theme = state.settings.theme
	app.font_size = state.settings.text_size
	if !font_init(app.dpi) {
		fmt.eprintln("Deckhand: could not load a font (", TEXT_BACKEND, ")")
		os.exit(1)
	}
	ui_init()
	core.platform = platform_app()
	win_os = win_os_app() // the window's own (win_os.odin)
	// the saved setting: never the user's own workspace.json in test mode without a data dir
	// (that run's is build/test-data, as home_root below)
	mode_data := core.data_dir(context.temp_allocator)
	if core.hook_env(.Script) != "" && core.hook_env(.Data_Dir) == "" {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		mode_data = strings.concatenate({cwd, "/build/test-data"}, context.temp_allocator)
	}
	// the core as another process (client_core.odin): the setting, or (turned off) a core of this
	// data dir that still runs: its sessions and core.lock are there, so this launch is its window.
	// fallback: no core came up and the user chose to run the sessions in Deckhand itself
	fallback := false
	if wanted := separate_core_wanted(mode_data); wanted || separate_core_running(mode_data) {
		if init_separate(wanted ? "" : "Sessions are still running in the background. Quit and Stop All Sessions to switch.") do return
		fallback = true // init_separate set the window up already
	}
	client_connect() // the window's link: the core's requests reach it while the workspace comes back (client.odin)
	if !fallback {
		app.window_active = true
		platform_window_init()
		platform_terminate_hook(on_terminate) // the Dock's Quit and logout (quit_route)
		menubar_install() // the macOS menu bar (menubar.odin)
	}
	// the OS appearance before anything is drawn, then its changes
	client_call(core.System_Appearance{light = platform_system_light()}, .Internal) // before the attach: straight in
	if !fallback {
		platform_watch_appearance()
		autotest_init()
	}
	if core.autotest_active do core.platform.notify = proc(title, body: string) {fmt.println("[autotest] notify:", title, "-", body)}
	if core.autotest_active do core.platform.notify_front = proc(title, body: string) {fmt.println("[autotest] notify (front):", title, "-", body)}
	// test mode keeps its log out of the user's data dir
	if core.autotest_active && core.hook_env(.Data_Dir) == "" {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		core.home_root = strings.concatenate({cwd, "/build/test-data"}) // absolute: Home's pi runs elsewhere
	} else do core.home_root = core.data_dir()
	if core.home_root == "" {
		// no home for this account in the user database (a release build never takes $HOME):
		// never a data dir relative to wherever Deckhand was started
		why := "Deckhand can't find your home folder (your account has no entry in the user database), so it has nowhere to keep its files"
		fmt.eprintln("Deckhand:", why)
		platform_alert("Deckhand can't start", why)
		os.exit(1)
	}
	// one Deckhand per data dir, and none beside a running pi-desk 0.1.x (instance.odin), before
	// anything is written there; test mode looks for Deckhand only in a runtime dir of its own
	check_old := !core.autotest_active || core.hook_env(.Runtime_Dir) != ""
	why := core.instance_guard(core.home_root, check_old)
	if why != "" && !core.autotest_active && instance_offer_end(why, core.instance_refused_by) do why = core.instance_guard(core.home_root, check_old)
	if why != "" {
		if core.autotest_active {
			fmt.println("[autotest] instance refused:", why)
			os.exit(3)
		}
		fmt.eprintln("Deckhand:", why)
		platform_alert("Deckhand can't start", why)
		os.exit(1)
	}
	core.event_log_open(core.home_root)
	// Atlas's prompt (an unedited older starter) and its copy of the guide (agent.odin)
	if core.home_root != "" {
		y, m, d := time.date(time.now())
		core.agent_prompt_migrate(fmt.tprintf("%04d-%02d-%02d", y, int(m), d))
		core.agent_guide_install()
	}
	// the session-title cache (titles.odin): same rule as the workspace
	if !core.autotest_active || core.hook_env(.Data_Dir) != "" do core.titles_load(core.data_dir(context.temp_allocator))
	core.claude_accounts_refresh() // Claude Code's config folders (claude_accounts.odin)
	core.rescan_now(claude = false) // pi's projects now; Claude's after the saved accounts are back
	// control socket (socket.odin); `--print-token script|control` mints a
	// token for local scripts and prints it once, as shell exports
	// (development and test builds only: a release build mints a control token only from
	// Settings › Copy a control token, test_hooks.odin)
	dir, token_kind := app_args.dir, app_args.token_kind
	if core.socket_start() && token_kind != "" {
		when core.TEST_HOOKS {
			kind := token_kind == "control" ? core.Caller_Kind.Control : core.Caller_Kind.Script
			fmt.printf("export DECKHAND_SOCKET='%s' DECKHAND_TOKEN='%s'\n", core.socket_path(), core.socket_mint_token({kind = kind}, context.temp_allocator))
			os.flush(os.stdout)
		}
	}
	// the saved workspace (persist.odin); test mode only with an explicit
	// DECKHAND_DATA_DIR, so scripts never read or write the user's
	core.settings_defaults() // until the saved workspace says otherwise (the core's, before the window attaches)
	if !core.autotest_active || core.hook_env(.Data_Dir) != "" {
		core.persist_init(core.data_dir(context.temp_allocator))
		core.claude_disk_launching = true // no transcript read on the main thread while it comes back
		core.persist_load(app_args.fresh)
		core.claude_disk_launching = false
	}
	// the session holder: tabs whose processes it kept since the last run get them back now
	// (holder_adopt.odin); with keep_sessions on it is connected (or launched) here
	core.holder_adopt_all()
	core.harness_no_sudo_sweep(at_quit = false) // no-sudo folders of runs whose Deckhand is gone (harness_install.odin)
	// Claude's projects (claude_disk.odin), on the Rescan worker, with the saved accounts (added
	// ones in, removed ones out)
	if core.claude_startup_rescan_due() do core.run_command(core.Rescan{}, {kind = .Internal})
	// the chats folder's instructions (folders.odin), then the first-run sheet
	// once while no main folder is set (test mode: only when a scene asks)
	// (not while setup is due: Done writes it where the user puts chats)
	if (!core.autotest_active || core.hook_env(.Data_Dir) != "") && !core.setup_due() do core.chats_instructions_ensure(core.date_stamp())
	if core.setup_due() && (!core.autotest_active || core.hook_env(.First_Run) == "1") do core.run_command(core.Setup_Sheet{open = true})
	// `deckhand DIR` adds/selects DIR and starts a new chat there.
	if dir != "" {
		r := core.run_command(core.Add_Project{dir})
		// only in DIR's own project: a failed add starts nothing (never the one selected before)
		app.launch_project = launch_project(r)
		if app.launch_project != 0 do app.pending_start = true
		else do fmt.eprintfln("Deckhand: %s: %s", dir, r.error)
	}
	core.update_init() // Deckhand's own updates: saved choices, leftovers, the check timer (update.odin)
	client_attach() // the window as its core's client: `state` is the replica from here on (client.odin)
	if fallback { // saved, so the next launch runs in process too
		client_call(core.Set_Separate_Core{on = false})
		toast_show("Sessions run in Deckhand itself: turn Settings › Sessions in a background core on to try it again")
	}
	app.ready = true
	app.redraw = true
	core.core_loop_start() // core_tick also while no frames run (core_loop.odin)
}

// init with a separate core (client_core.odin): the window's own setup, then the core's link.
// Nothing of the core runs here: no instance lock, socket, workspace, holder, jobs or core loop
// (the core process has them). The first-run sheet is the in-process window's only for now.
// note: a toast once attached. False: no core came up and the user chose to run the sessions in
// Deckhand itself (init goes on in process; the window is set up).
init_separate :: proc(note := "") -> bool {
	app.window_active = true
	platform_window_init()
	platform_terminate_hook(on_terminate)
	menubar_install()
	platform_watch_appearance()
	autotest_init()
	script_drain = client_drain // the script's commands go over core.sock
	if core.autotest_active do core.platform.notify = proc(title, body: string) {fmt.println("[autotest] notify:", title, "-", body)}
	if core.autotest_active do core.platform.notify_front = proc(title, body: string) {fmt.println("[autotest] notify (front):", title, "-", body)}
	if core.autotest_active && core.hook_env(.Data_Dir) == "" {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		core.home_root = strings.concatenate({cwd, "/build/test-data"})
	} else do core.home_root = core.data_dir()
	if core.home_root == "" {
		platform_alert("Deckhand can't start", "Deckhand can't find your home folder, so it has nowhere to keep its files")
		os.exit(1)
	}
	why := client_core_connect(core.home_root)
	// a leftover Deckhand process holds the data dir's lock (#78): the user may end it, then the core starts
	if why != "" && !core.autotest_active && instance_offer_end(why, core.instance_holder_now(core.home_root)) do why = client_core_connect(core.home_root)
	if why != "" && client_core_offer_previous() do why = client_core_connect(core.home_root)
	if why != "" {
		fmt.eprintln("Deckhand:", why)
		if core.autotest_active {
			fmt.println("[autotest] core refused:", why)
			os.exit(3)
		}
		if platform_ask("Deckhand can't start its background core", fmt.tprintf("%s. You can run your sessions in Deckhand itself instead (Settings › Sessions in a background core turns it on again).", why), "Run Sessions in Deckhand Itself", "Quit") {
			script_drain = core.inbox_drain
			client_core_abandon()
			return false
		}
		os.exit(1)
	}
	if core.autotest_active do fmt.printfln("[autotest] core: attached to pid %d", client.core_pid)
	if note != "" do toast_show(note)
	// `deckhand DIR`: DIR's project, and a new chat there once the pane has a size
	if app_args.dir != "" {
		r, _ := client_call_wait(core.Add_Project{app_args.dir}, 5 * time.Second)
		app.launch_project = launch_project(r)
		if app.launch_project != 0 do app.pending_start = true
		else do fmt.eprintfln("Deckhand: %s: %s", app_args.dir, r.error)
	}
	client_internal(core.System_Appearance{light = platform_system_light()})
	// what the window's views read from the core package's caches of the disk (accounts, titles)
	core.claude_accounts_refresh()
	if !core.autotest_active || core.hook_env(.Data_Dir) != "" do core.titles_load(core.data_dir(context.temp_allocator))
	// the first-run sheet, as in process: while no main folder is set (test mode: when a scene asks)
	if core.setup_due() && (!core.autotest_active || core.hook_env(.First_Run) == "1") do ui_do(core.Setup_Sheet{open = true})
	app.ready = true
	app.redraw = true
	// frames stop while hidden: the core's messages are read by a timer then (and the script runs)
	core.platform.core_timer(50 * time.Millisecond, proc() {
		if time.tick_since(app.last_frame_at) < 50 * time.Millisecond do return
		client_core_tick() // the core's connection ended: dial again (client_core.odin)
		client_drain()
		autotest_step()
	})
	return true
}

// A lock in the data dir is held by h (instance_guard refused, or the core did: why). When h is a
// leftover Deckhand process (lock_holder_endable), the user is asked to end it: true = ended, start
// again. Declined: Deckhand quits (the same alert would follow).
instance_offer_end :: proc(why: string, h: core.Lock_Holder) -> bool {
	if !core.lock_holder_endable(h) do return false
	text := fmt.tprintf("%s\n\nIt is a Deckhand process left over from an earlier run (its app has quit), %s. Ending it lets Deckhand start.", why, core.lock_holder_text(h))
	if !platform_ask("Deckhand can't start", text, "End It and Start", "Quit") do os.exit(1)
	if core.lock_holder_end(h) do return true
	platform_alert("Deckhand can't start", fmt.tprintf("%s could not be ended. Quit it in Activity Monitor, then open Deckhand again.", core.lock_holder_text(h)))
	os.exit(1)
}

// The app's platform layer: every entry set (a nil one would make its
// commands do nothing without a word).
platform_app :: proc() -> core.Platform {
	return {
		quit = proc() {
			core.app_quitting = true
			app_request_quit()
		},
		wake = platform_wake,
		run_later = platform_run_later,
		notify = platform_notify,
		notify_front = platform_notify_front,
		trash = fs_trash, // editor_platform_*.odin
		activity = platform_activity,
		core_timer = platform_core_timer,
	}
}

// The window's own OS layer (win_os.odin): what the core asks with a window.request, and what
// window code uses itself.
win_os_app :: proc() -> Win_OS {
	return {
		set_clipboard = proc(text: string) {sapp.set_clipboard_string(strings.clone_to_cstring(text, context.temp_allocator))},
		get_clipboard = proc() -> string {return string(sapp.get_clipboard_string())},
		pick_folder = platform_pick_folder,
		set_appearance = platform_set_appearance,
		reveal = platform_reveal,
		left_button = platform_left_button,
		open_url = platform_open_url,
		clipboard_count = platform_clipboard_count,
		set_clipboard_secret = platform_clipboard_set_secret,
		clear_clipboard_if = platform_clipboard_clear_if,
		set_badge = platform_set_badge,
		play_sound = platform_play_sound,
	}
}

// Ends the run as sokol does, from its next frame, by closing the window. AppKit never closes a
// window while the app is hidden (⌘H): the quit would wait until the user showed it again, so it is
// shown first (without taking focus): the window shows for a moment before it closes. With no
// frames at all (minimised, App Nap), the core loop's timer closes it (core_quit_stalled).
app_request_quit :: proc() {
	if app_is_hidden() do app_unhide()
	app.close_asked = time.tick_now()
	sapp.request_quit()
}

// A separate core's close that waits for a frame that does not come (minimised, App Nap), as
// core_quit_stalled is for the in-process quit: the window timer closes the window itself.
separate_close_stalled :: proc(now: time.Tick) -> bool {
	if !client_separate() || app.close_asked == {} do return false
	return time.tick_diff(app.close_asked, now) >= core.QUIT_STALL_AFTER && time.tick_diff(app.last_frame_at, now) >= core.QUIT_STALL_AFTER
}

// The window's side of the core's hooks (window_hooks.odin): the redraw signal and test mode's;
// everything else is a message (window_requests.odin, client.odin's facts). Filled in before main
// runs so the unit tests have them too.
window_hooks_app :: proc() -> core.Window_Hooks {
	return {
		state_changed = proc() {app.redraw = true},
		test_step = autotest_step,
		test_event = autotest_on_event,
		test_facts = client.host ? client_test_facts : nil, // the unit tests' host link (client.odin)
	}
}

@(init)
window_hooks_init :: proc "contextless" () {
	context = runtime.default_context()
	core.window = window_hooks_app()
}

// The OS switched between light and dark (platform layer, main thread; the
// test mode's `system_appearance` too).
on_system_appearance :: proc(light: bool) {
	client_internal(core.System_Appearance{light = light})
}

// UI actions go through the inbox like every other caller; event() drains it
// right after, so they apply in order before the next event.
ui_do :: proc(cmd: core.Command) {
	deck_follow(cmd) // a session or tab opened: the Deck view goes (ui_deck.odin)
	if window_only_quit(cmd) do return
	if lost_core_save(cmd) do return
	// a separate core: which widget has the keyboard is the core's (state.focus_widget), so the
	// next event waits for it (bounded: client_before_event) before it is routed, as in process
	// (⌘K, then typing). Not here: the caller may hold a view a delta's View_Drop would free.
	if _, is := cmd.(core.Set_Focus); is && client_separate() && client.sock != nil {
		client_send_focus(cmd) // client.odin
		return
	}
	client_send(cmd) // client.odin
}

// A Quit from the window (⌘Q, the menus, the palette): with a separate core, Quit Deckhand closes
// the window and the sessions run on in the core; Quit Deckhand and Stop All Sessions, and a
// confirmation's answer, reach the core (quit_route). True: handled here.
window_only_quit :: proc(cmd: core.Command) -> bool {
	q, is := cmd.(core.Quit)
	if !is || q.confirm != "" do return false
	if quit_route(q.stop_sessions ? .Stop_All : .Menu, client_separate(), app_closing()) != .Close_Window do return false
	app_request_quit()
	return true
}

// ⌘S with the separate core gone (client.lost): the window saves the buffer itself, as the core's
// tab host call would have had it do, so unsaved work is never stuck behind a dead core.
lost_core_save :: proc(cmd: core.Command) -> bool {
	c, is := cmd.(core.Save_File)
	if !is || !client.lost do return false
	r, _ := editor_apply(c, {kind = .UI})
	if !r.ok do toast_show(r.error, true)
	return true
}

// ---- the quit paths (docs/plans/background-core.md §6, §10.3 M4-D) ----

Quit_From :: enum u8 {
	Menu, // ⌘Q, the menu's or palette's Quit, the window's close button
	Dock, // -[NSApp terminate:] with no reason: the Dock's Quit, a script's `quit app "Deckhand"`
	Logout, // ...with one: log out, restart, shut down
	Stop_All, // Quit Deckhand and Stop All Sessions…
}

Quit_Do :: enum u8 {
	Terminate, // go now; cleanup does the rest
	Ask_Core, // Quit{} to the core: it asks if anything would stop, then the window closes (in process: the holder's handover)
	Close_Window, // a separate core: only the window closes; the core and its sessions run on
	Stop_All, // Quit{stop_sessions} to the core: it persists, hangs up the holder's sessions and exits; the window follows
}

// What a quit does. quitting: one already went through (a confirmed Quit, the window closing):
// macOS's terminate after the last window closed goes ahead. Logout: both sides save and exit
// (the core on the SIGTERM launchd sends it, in process cleanup's save); today's restore follows.
quit_route :: proc(from: Quit_From, separate, quitting: bool) -> Quit_Do {
	if quitting do return .Terminate
	switch from {
	case .Logout: return .Terminate
	case .Stop_All: return .Stop_All
	case .Menu, .Dock: return separate ? .Close_Window : .Ask_Core
	}
	return .Terminate
}

app_closing :: proc() -> bool {return core.app_quitting || app.closing}

// -[NSApp terminate:] (platform_terminate_hook): the Dock's Quit is ⌘Q; logout goes now. 1:
// terminate now; 0: not yet (the quit goes its usual way and terminates once the window closed).
on_terminate :: proc "c" (logout: c.int) -> c.int {
	context = core.app_context
	from := logout != 0 ? Quit_From.Logout : .Dock
	if core.autotest_active do fmt.println("[autotest] terminate:", from)
	switch quit_route(from, client_separate(), app_closing()) {
	case .Terminate: return 1
	case .Ask_Core: ui_do(core.Quit{})
	case .Close_Window: app_request_quit()
	case .Stop_All: ui_do(core.Quit{stop_sessions = true})
	}
	return 0
}

// The first time the window closes over a separate core: a word that the sessions run on, and how
// to stop them (once per data dir: QUIT_NOTICE_FILE).
QUIT_NOTICE_FILE :: "background-core-noticed"

quit_notice_once :: proc() {
	if core.home_root == "" do return
	path := fmt.tprintf("%s/%s", core.home_root, QUIT_NOTICE_FILE)
	if os.exists(path) do return
	_ = os.write_entire_file(path, transmute([]u8)string("shown\n"))
	if core.autotest_active {
		fmt.println("[autotest] quit notice")
		return
	}
	platform_alert("Your sessions keep running", "Deckhand's window closes, and its background core keeps your sessions and jobs running. Open Deckhand again to see them. To stop them too, choose Quit Deckhand and Stop All Sessions… in the Deckhand menu.", "OK")
}

// A menu row's command: as ui_do, then its outcome is shown where nothing
// else would show it (menu_result: a failure, a copy).
ui_do_menu :: proc(cmd: core.Command, label: string) {
	if window_only_quit(cmd) do return
	if lost_core_save(cmd) do return
	client_send(cmd, menu = label)
}

frame :: proc "c" () {
	context = core.app_context
	defer free_all(context.temp_allocator)

	if script_frames_off() do return // test mode: as if macOS stopped calling frame() (autotest.odin)
	core.core_frame_begin(time.tick_now()) // the core loop's timer stays out of frames (core_loop.odin)
	defer core.core_frame_end(time.tick_now()) // and runs a tick it skipped meanwhile
	core.app_frames_called += 1
	client.busy += 1 // the replica's retired blocks wait for client_after_tick (client.odin)
	defer client.busy -= 1
	client_facts() // what the last event changed of the window's facts, before the core reads them (client.odin)
	if client_separate() { // the core is another process: what it sent, then the script's step
		app.last_frame_at = time.tick_now()
		client_core_tick() // the core's connection ended: dial again (client_core.odin)
		client_drain()
		client_live_mirror() // the core's install run and watched folders (client_core.odin)
		autotest_step()
	} else do core.core_tick() // inbox, the test step, terminals, persistence, jobs, Claude (core_loop.odin)
	client_after_tick() // what the tick changed, into the window's replica (client.odin)
	closed_tabs_settle() // the user's closes that went through (closed_tabs.odin)
	term_views_tick() // hidden tabs' terminal copies detach; a snapshot's history (term_view_stream.odin)
	peek_tick() // a peek whose tab, session or machine went closes (ui_peek.odin)
	editor_tick() // files changed on disk, git gutter (editor_watch.odin)
	browser_debug_tick() // DECKHAND_DEBUG_BROWSER (browser.odin, spike)
	t := active_view() // the window's copies of the terminals it shows (term_view_stream.odin)
	// Output-driven redraws are capped near 60 Hz; input redraws at once.
	at := agent_view() // Atlas's terminal in the drawer (also while it slides out)
	pv := peek_view() // a peeked tab's, over the centre (ui_peek.odin)
	drags_follow_focus()
	left_down := win_os.left_button == nil || win_os.left_button()
	if t != nil do term_drag_tick(t, left_down) // a selection dragged past the grid's edge scrolls
	if at != nil do term_drag_tick(at, left_down)
	shown_changed := false // a terminal in another pane on screen (panes.odin)
	for x in views_on_screen() do if x != t && x.changed do shown_changed = true
	if ((t != nil && t.changed) || shown_changed || (at != nil && at.changed && drawer_laid_out) || (pv != nil && pv.changed)) && time.tick_since(app.last_draw) > OUTPUT_FRAME do app.redraw = true
	if ui_wants_frame() do app.redraw = true // a fade or a running dot is moving
	if tip_due() do app.redraw = true // the pointer rested on a control: one frame for its tooltip
	if toast_tick() do app.redraw = true // a menu choice's outcome went away (toast.odin)
	holder_ask_tick() // a session holder from another build: asked once (below)
	if app_frames_tick() do app.redraw = true // app tabs: a frame arrived, an exit, a stall (app_tab.odin)
	dh_cef_pump_due() // CEF's pump when its timer is overdue (cef_macos.m)
	if browser_frames_tick() do app.redraw = true // browser tabs: a frame CEF painted (browser.odin)
	if browser_polish_pending_tick() do app.redraw = true // blocked popups held back a second (browser_polish.odin)
	if browser_agent_tick() do app.redraw = true // agents' reads, waits, screenshots, recordings (browser_agent.odin)
	if browser_act_tick() do app.redraw = true // agents' clicks, typing, uploads (browser_act.odin)
	app_focus_tick()
	// the display link: the screen's maximum while an app or page on screen is live, else at most
	// 120 (frames.odin)
	platform_display_link_cap(display_link_cap(app_frames_live() || browser_frames_live()))
	if !app.redraw do return // nothing changed: keep the last frame on screen
	app.last_draw = time.tick_now()
	// moved to a display with another scale, set_theme picked another look,
	// set_text_size another size or set_terminal_text_size the terminals'
	if d := sapp.dpi_scale(); d != app.dpi || state.settings.theme != app.font_theme || state.settings.text_size != app.font_size || font_config.mono_pt != term_text_pt() {
		app.dpi = d
		app.font_theme = state.settings.theme
		app.font_size = state.settings.text_size
		fonts_apply(theme_font_config(theme()), d)
		term_fits_forget() // new cell size: every terminal resizes at the next layout
	}

	w, h := sapp.widthf(), sapp.heightf()
	files_edit_check() // a Files name field that lost the keyboard ends its edit
	term_links_frame() // the link under the pointer, before the layout shows its tip (term_links.odin)
	cmds := ui_layout(w, h)
	bar_layout_done()
	peek_after_layout() // the peeked terminal's place in its panel; a tab never laid out gets its grid (ui_peek.odin)
	if at != nil {
		if x, y, tw, th, ok := drawer_term_rect(); ok do term_fit_rect(at.tab_id, x, y, tw, th)
	}
	harness_run_keep_sheet() // a running install keeps the setup sheet (harness_install.odin)
	harness_term_layout() // the setup sheet's install terminal (ui_harness.odin)
	if x, y, tw, th, ok := ui_terminal_rect(); ok {
		app.pane = {x, y, tw, th}
		cs := core.cur()
		ui_pane_rects(cs) // each pane's content rect (panes.odin): the core's (get_state, the room checks; M4: a fact)
		// and the replica's, which the window's own reads take (term_target_rect, tab_rect)
		if rs := find_session(state.current_session); rs != nil && rs != cs do ui_pane_rects(rs)
		if cs != nil && len(cs.panes) == 0 do if p := core.session_focused_pane(cs); p != nil do p.rect = app.pane // the implicit pane: the centre's
		panes_fit_terms() // every terminal tab to its pane's rect (ui_panes.odin)
	}
	if app.pane.z > 0 && !client_separate() do core.persist_after_layout(skip = app.pending_start)
	browser_tick() // browser tabs follow the pane; new textures (browser.odin)
	annot_tick() // their annotation overlays and markers (browser_annotate.odin)
	browser_polish_tick() // their zoom, bars and fields (browser_polish.odin)
	if app.pending_start && app.pane.z > 0 {
		app.pending_start = false
		cmd := launch_start(app_args.claude, app.launch_project)
		if _, is := cmd.(core.New_Claude_Session); is do client_call(cmd) // the user's: in front, toast if Claude Code is missing
		else if cmd != nil && client_separate() do client_call(cmd)
		else if cmd != nil do core.run_command(cmd)
		t = active_view()
	}

	editors_frame_begin() // an editor takes hits only where this frame draws it (editor_view.odin)
	annot_frame_begin() // and comment badges where this frame draws them (browser_annotate.odin)
	draw_begin(w, h)
	// chrome, the current tab, the sliding drawer, then a tab drag's drop indicator and ghost, the palette, menus, popover, sheet, tooltip
	overlay := cmds.length
	for name in ([]string{"tab_drop", "tab_ghost", "palette_scrim", "wt_menu_shadow", "wt_menu", "menu_shadow", "menu", "settings_shadow", "settings_pop", "bell_shadow", "bell_pop", "sheet_scrim", "setup_scrim", "jobsheet_scrim", "peek_scrim", "linktip", "toast", "tooltip"}) do overlay = min(overlay, ui_overlay_start(cmds, name))
	drawer_at := min(ui_overlay_start(cmds, "drawer"), overlay)
	ui_draw(cmds, 0, drawer_at)
	typing := state.focus_widget == "" // no text field has the keyboard
	// the tab each pane shows, in its pane (pages and apps too); marked text in the focused one's (panes.odin)
	if deck.shown {
		// the Deck view takes the centre: no pane draws (ui_deck.odin)
	} else if cs := core.cur(); cs != nil && len(cs.panes) > 1 {
		panes_draw(cs, t, typing) // and their dim, the focus line, a zoom's outline (ui_pane_motion.odin)
	} else if p := core.focused_pane(); p != nil {
		pane_draw(p, t, typing)
	} else if vs := core.cur_view(); vs != nil && vs.machine != 0 {
		pane_draw(core.session_focused_pane(vs), t, typing) // another machine's: its one pane, a relayed terminal
	} // else the layout's empty state shows
	ui_draw(cmds, drawer_at, overlay)
	if at != nil && agent_running() {
		if _, _, tw, th, ok := drawer_term_rect(); ok && tw > 0 && th > 0 {
			term_draw(at)
			if state.focus_widget == "agent_input" do term_draw_marked(at, ime.marked, ime.caret)
		}
	}
	if peek_is_open() {
		// the palette and popovers, then the peek's scrim and panel with its terminal (all at its
		// fade), then what is above it (the toast, tooltips)
		pf, pt := peek_commands(cmds)
		ui_draw(cmds, overlay, pf)
		draw_alpha = peek_progress()
		ui_draw(cmds, pf, pt)
		peek_draw()
		draw_alpha = 1
		ui_draw(cmds, pt, cmds.length)
	} else do ui_draw(cmds, overlay, cmds.length) // the palette, above the terminals
	if setup_open() do harness_term_draw() // the setup sheet's install terminal, on the sheet
	ui_draw_field_cursor(cmds)
	draw_end()
	update_window_title()
	dock_badge_update(core.fleet_need(fleet)) // the sessions that need you, on the Dock icon: this frame's count (win_os.odin)
	font_upload() // glyphs added while drawing, before the pass that uses them

	bg := theme().bg_app
	clear := sg.Color{f32(bg.r) / 255, f32(bg.g) / 255, f32(bg.b) / 255, 1}
	sg.begin_pass({action = {colors = {0 = {load_action = .CLEAR, clear_value = clear}}}, swapchain = sglue.swapchain()})
	sgl.draw()
	sg.end_pass()
	sg.commit()
	app_frames_committed() // slots this frame stopped showing go back once its GPU work is done
	browser_frames_committed() // the same for browser tabs
	app.redraw = font_frame_done() // the atlas grew or started over: draw again
	if t != nil do t.changed = false
	for x in views_on_screen() do x.changed = false // every pane's terminal was drawn
	if at != nil do at.changed = false
	if v := peek_view(); v != nil do v.changed = false // (looked up again: a pump since may have dropped it)
	app.frames_drawn += 1
	platform_frame_drawn()
}

// A drag belongs to the tab it started in: when the focused tab changes (a
// tab or session switch from a key, a click or a command), drags in tabs
// that left the screen end, so a release that lands elsewhere cannot leave
// one going. A tab still on screen (another pane's: panes.odin) keeps its
// drag.
drags_follow_focus :: proc() {
	id: u64
	if tab := core.active_tab(); tab != nil do id = tab.id
	if id == app.drag_tab do return
	app.drag_tab = id
	for tab_id, x in term_views do if !core.tab_on_screen(tab_id) do term_cancel_drag(x)
}

over_sidebar :: proc(x: f32) -> bool {
	l, _ := column_widths()
	return x < l * app.dpi
}
over_right_column :: proc(x: f32) -> bool {
	_, r := column_widths()
	return r > 0 && x >= sapp.widthf() - r * app.dpi
}

// OS events. In script mode (DECKHAND_SCRIPT) real keyboard/mouse input is
// dropped so keystrokes meant for another app can never reach the child.
event_os :: proc "c" (e: ^sapp.Event) {
	context = core.app_context
	defer free_all(context.temp_allocator)
	if core.autotest_active && !autotest.injecting {
		#partial switch e.type {
		case .KEY_DOWN, .KEY_UP, .CHAR, .MOUSE_DOWN, .MOUSE_UP, .MOUSE_MOVE, .MOUSE_SCROLL, .CLIPBOARD_PASTED, .MOUSE_ENTER, .MOUSE_LEAVE, .FILES_DROPPED:
			return
		}
	}
	event(e)
}

event :: proc(e: ^sapp.Event) {
	client.busy += 1 // as in frame(): no release mid-event (client_on_drain)
	defer client.busy -= 1
	client_before_event() // the replica holds what timers did since the last frame (client.odin)
	defer client_drain()
	// the press's pane lets go (ui_panes.odin); leaving the window keeps it (the release may come back)
	defer if e.type == .MOUSE_UP || e.type == .UNFOCUSED do pane_release()
	if e.type == .UNFOCUSED do pane_divider_release() // a divider drag ends where it is
	term_links_event(e) // ⌘ down or up, before anything takes the key (term_links.odin)
	drags_follow_focus() // a tab switch the last event or a command made
	if e.type == .MOUSE_DOWN do count_click(e.mouse_x, e.mouse_y)
	if e.type == .MOUSE_DOWN || e.type == .KEY_DOWN || e.type == .MOUSE_SCROLL do tip_dismiss()
	only_cmd := e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT) == sapp.MODIFIER_SUPER
	// the job sheet (ui_job_sheet.odin) is modal: it takes all input, the
	// global ⌘ shortcuts too (they would move the keyboard from under it),
	// and files dropped on it go nowhere; ⌘Q still quits
	if job_sheet_open() {
		#partial switch e.type {
		case .KEY_DOWN, .KEY_UP, .CHAR, .MOUSE_DOWN, .MOUSE_UP, .MOUSE_MOVE, .MOUSE_SCROLL, .CLIPBOARD_PASTED, .FILES_DROPPED:
			if e.type == .KEY_DOWN {
				app.key_in_widget = true
				app.key_taken = false
			}
			if (e.type == .CHAR || e.type == .KEY_UP) && app.key_taken do return
			if e.type == .FILES_DROPPED || job_sheet_event(e) do return // dropped files: sidebar_drop refuses them too
		}
	}
	// a peek (ui_peek.odin) is for looking: like the bell's popover it takes the keys and clicks
	// (nothing reaches its terminal or what is under it); a ⌘ chord not its own closes it and goes on
	if peek_event(e) do return
	// ⌘K opens the palette from anywhere, and closes it
	if e.type == .KEY_DOWN && e.key_code == .K && only_cmd {
		ime_cancel()
		if !palette_is_open() do palette_reset()
		ui_do(core.Set_Focus{palette_is_open() ? "" : "palette"})
		return
	}
	// ⌘P opens a file of the current project (the palette's file mode), and closes it
	if e.type == .KEY_DOWN && e.key_code == .P && only_cmd {
		ime_cancel()
		palette_open_files()
		return
	}
	// ⌘J shows or hides the agent's drawer from anywhere (the palette
	// closes); an open drawer without the keyboard (pinned) gets it first
	if e.type == .KEY_DOWN && e.key_code == .J && only_cmd {
		ime_cancel()
		was_palette := palette_is_open()
		if was_palette do ui_do(core.Set_Focus{""})
		if state.home_open && state.focus_widget != "agent_input" && !was_palette && core.home_tab() != nil && core.home_tab().status == .Running do ui_do(core.Set_Focus{"agent_input"})
		else do ui_do(core.Set_Home{open = !state.home_open})
		return
	}
	// ⌘, the Settings tab of the left column with the keyboard (again: back
	// to Sessions) and ⌘/ keyboard shortcuts (again: closes), from anywhere;
	// in an editor tab with the keyboard ⌘/ toggles a comment instead (as in
	// every code editor); the sheet is still on its button and in the
	// palette. The gear's popover: a click on the gear.
	if e.type == .KEY_DOWN && only_cmd && (e.key_code == .COMMA || (e.key_code == .SLASH && !editor_takes_cmd_slash())) {
		ime_cancel()
		if menu.open do menu_close()
		if e.key_code == .COMMA {
			if state.layout.left_open && state.layout.left_tab == .Settings && state.focus_widget == "files" {
				ui_do(core.Set_Left_Tab{tab = .Sessions})
				ui_do(core.Set_Focus{""})
			} else do action_run("settings")
		} else do ui_do(core.Set_Focus{state.focus_widget == "shortcuts" ? "" : "shortcuts"})
		app.key_taken = true
		return
	}
	// ⇧⌘F: the left column's filter, from anywhere
	if e.type == .KEY_DOWN && e.key_code == .F && e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT) == sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT {
		ime_cancel()
		if menu.open do menu_close()
		filter_focus()
		app.key_taken = true
		return
	}
	// ⇧⌘N: a new session in the selected project (⌘N is a new chat; both the harness picker, harness.odin)
	if e.type == .KEY_DOWN && e.key_code == .N && e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT) == sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT {
		ime_cancel()
		if menu.open do menu_close()
		action_run("new_session")
		app.key_taken = true
		return
	}
	// the panes' keys (ui_panes.odin): ⌘D ⇧⌘D split, ⌃⌘arrows focus, ⌃⇧⌘arrows move the tab,
	// ⇧⌘W unsplit; from anywhere but a text field
	if e.type == .KEY_DOWN && state.focus_widget == "" && pane_key(e) {
		ime_cancel()
		if menu.open do menu_close()
		app.key_taken = true
		return
	}
	// ⇧⌘E: the Files tab with the keyboard, from anywhere; again: back to Sessions
	if e.type == .KEY_DOWN && e.key_code == .E && e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT) == sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT {
		ime_cancel()
		if menu.open do menu_close()
		if files_shown() && state.focus_widget == "files" {
			ui_do(core.Set_Left_Tab{tab = .Sessions})
			ui_do(core.Set_Focus{""})
		} else do action_run("show_files")
		app.key_taken = true
		return
	}
	// a key that a widget took (Enter, Esc) may close it: its CHAR and
	// KEY_UP events must not reach the terminal then
	if e.type == .KEY_DOWN {
		app.key_in_widget = state.focus_widget != ""
		app.key_taken = false
	}
	if (e.type == .CHAR || e.type == .KEY_UP) && (app.key_taken || app.key_in_widget && state.focus_widget == "") do return
	// an open menu (context or sort) takes all input until it closes
	if menu.open && menu_event(e) {
		if e.type == .KEY_DOWN do app.key_taken = true
		return
	}
	if wt_menu.open && wt_menu_event(e) { 	// the Files tab's checkout switcher (ui_worktrees.odin)
		if e.type == .KEY_DOWN do app.key_taken = true
		return
	}
	// a column divider being dragged follows the pointer
	if divider.active {
		#partial switch e.type {
		case .MOUSE_MOVE:
			divider_move(e.mouse_x)
			return
		case .MOUSE_UP, .MOUSE_LEAVE:
			divider_release()
			return
		}
	}
	// and a pane divider (ui_panes.odin)
	if pane_drag.active {
		#partial switch e.type {
		case .MOUSE_MOVE:
			pane_divider_move(e.mouse_x, e.mouse_y)
			return
		case .MOUSE_UP, .MOUSE_LEAVE:
			pane_divider_release()
			pane_release()
			return
		}
	}
	// a press on a tab owns the pointer until its release; past a few px it drags the tab (panes_drag.odin)
	if tab_drag_event(e) do return
	// the settings popover and the shortcuts sheet take all input while open
	if settings_open() && settings_event(e) do return
	if shortcuts_open() && shortcuts_event(e) do return
	if setup_open() && setup_event(e) do return // the first-run sheet (ui_setup.odin)
	if bell_open() && bell_event(e) do return
	if deck_event(e) do return // the Deck view: its keys, the pointer over it; nothing reaches the panes under it (ui_deck.odin)
	// a press on a pane divider drags it; a press in a pane without the keyboard focuses it first,
	// then acts in it, a page or an app too (click-through: ui_panes.odin)
	if e.type == .MOUSE_DOWN && e.mouse_button == .LEFT && !over_overlay() && !(state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y)) {
		if split := pane_divider_at(e.mouse_x, e.mouse_y); split != 0 {
			pane_divider_press(split, app.clicks)
			app.redraw = true
			return
		}
	}
	if e.type == .MOUSE_DOWN && !over_overlay() && !(state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y)) do pane_press(e)
	// the per-tab handlers get the pane the event is for: the pointer's (the press's while a
	// button is held), the focused one's for keys; their Clay ids are its (cid)
	fp := event_pane(e)
	if e.type == .MOUSE_MOVE do pane_pointer_moved(e) // the pane it left hears it leave (ui_panes.odin)
	old_ids := ids_pane_begin(fp)
	defer ids_pane_end(old_ids)
	// the editor's find/replace/go-to fields take Enter, Esc and ⌘G first
	if editor_bar_focused() && editor_bar_event(core.focused_pane(), e) do return // its field has the keyboard
	if changes_field_key(e) do return // the commit message's Enter and Esc (ui_changes.odin)
	if comments_field_key(e) do return // a comment's edit field: Enter and Esc (ui_comments.odin)
	if browser_url_key(fp, e) do return // a browser tab's URL field: Enter and Esc (browser_nav.odin)
	if browser_polish_event(fp, e) do return // a browser tab's bars, ⋯, ⌘F, zoom keys, pointer shape (browser_polish.odin)
	if state.focus_widget != "" && widget_event(e) do return
	if drawer_event(e) do return // the drawer: resizing, the mouse in Atlas's terminal
	if files_event(e) do return // the Files tab: rows, drag, its keys (ui_files.odin)
	if changes_event(fp, e) do return // the Changes tab's list, bars and keys, the "±" button (ui_changes.odin)
	if markdown_event(fp, e) do return // a Markdown tab's preview: wheel, keys, links (markdown_view.odin)
	// an editor tab: its keys while it has the keyboard, mouse and wheel over it
	// (under a Markdown preview only its toolbar and find bar: the source editor is hidden)
	if ed := pane_editor(fp); ed != nil && (!md_preview_shown(fp) || e.type == .MOUSE_DOWN) && editor_event(ed, e) do return
	if annot_event(fp, e) do return // a browser tab's Annotate, badges, comment mode (browser_annotate.odin)
	if browser_event(fp, e) do return // a browser tab on screen: the page gets it (browser.odin)
	if app_event(fp, e) do return // an app tab on screen: the app gets it (app_tab.odin)
	// the session on screen's, whichever machine's: another machine's terminals are relayed copies
	// and its tabs' commands run there (machine_route.odin)
	t := active_view()
	mt := pane_view(fp) // the pointer's: the pane under it (or holding its press)
	tab := core.active_tab_view()
	cs := core.cur_view()
	kt := key_view()
	ktab := core.key_tab_view()
	#partial switch e.type {
	case .KEY_DOWN:
		if e.modifiers & sapp.MODIFIER_SUPER != 0 {
			#partial switch e.key_code {
			case .C: if ktab != nil do ui_do(core.Copy_Selection{ktab.id})
			case .Q: ui_do(core.Quit{})
			// ⌘N: a chat (Chats; the harness picker, harness.odin); ⇧⌘N: a session in the selected project. ⌥⌘T: a Claude tab
			case .N: if e.modifiers & sapp.MODIFIER_ALT == 0 do action_run("new_chat")
			case .T: // ⇧⌘T: reopen the last tab the user closed (closed_tabs.odin)
				if e.modifiers & sapp.MODIFIER_SHIFT != 0 {
					if e.modifiers & sapp.MODIFIER_ALT == 0 do action_run("reopen_closed_tab")
				} else if e.modifiers & sapp.MODIFIER_ALT != 0 do action_run("new_claude_tab")
				else if cs != nil do ui_do(core.New_Shell_Tab{session = cs.id})
			case .L: // a browser tab: its URL field (browser_nav.odin); else the menu bar's (Go to line)
				if tab_browser() != nil do browser_url_focus()
				else if id := menubar_key_action(e.key_code, e.modifiers); id != "" do action_run(id)
			case .W:
				if state.focus_widget == "agent_input" do ui_do(core.Set_Home{open = false}) // the drawer, never the tab under it
				else if tab != nil do close_tab_click(tab.id) // like its ×
			case .B:
				if e.modifiers & sapp.MODIFIER_ALT != 0 do ui_do(core.Set_Layout{right_open = !state.layout.right_open})
				else do ui_do(core.Set_Layout{left_open = !state.layout.left_open})
			case ._1 ..= ._9:
				if e.modifiers & sapp.MODIFIER_ALT != 0 { 	// ⌥⌘1–⌥⌘6: the Open section's rows (actions.odin)
					if id := menubar_key_action(e.key_code, e.modifiers); id != "" do action_run(id)
				} else if cmd, ok := tab_nth(int(e.key_code) - int(sapp.Keycode._1)); ok do ui_do(cmd) // in the focused pane (actions.odin)
			case .BACKSPACE, .LEFT, .RIGHT: // ⌘⌫ ⌘← ⌘→ alone: line editing (term.odin, mac_key_text)
				if kt != nil && mac_key_text(e.key_code, e.modifiers, false) != "" {
					core.claude_note_typed(ktab)
					term_key_down(kt, e)
				}
			case: // shortcuts only the menu bar has (⌘+, ⇧⌘], ⌥⌘↓…; menubar.odin)
				if id := menubar_key_action(e.key_code, e.modifiers); id != "" && (id != "markdown_preview" || md_takes_keys()) do action_run(id)
			}
			return // Cmd+V arrives as CLIPBOARD_PASTED
		}
		// a Claude tab's prompt holds text now: Deckhand holds what it would send (claude.odin);
		// Enter submits it (its hook says so) and Esc does not add text
		if kt != nil && e.key_code != .ENTER && e.key_code != .KP_ENTER && e.key_code != .ESCAPE do core.claude_note_typed(ktab)
		if kt != nil do term_key_down(kt, e)
	case .KEY_UP:
		if kt != nil && e.modifiers & sapp.MODIFIER_SUPER == 0 do term_key_up(kt, e)
	case .CHAR:
		if kt != nil && e.modifiers & sapp.MODIFIER_SUPER == 0 do term_char(kt, e)
	case .CLIPBOARD_PASTED:
		core.claude_note_typed(ktab)
		if ktab != nil do ui_do(core.Send_Text{ktab.id, clipboard_text()})
	case .FILES_DROPPED:
		paths := make([]string, sapp.get_num_dropped_files(), context.temp_allocator)
		for &p, i in paths do p = string(sapp.get_dropped_file_path(i32(i)))
		sidebar_drop(paths, e.mouse_x, e.mouse_y) // where it was dropped (sokol sets the pointer)
	case .MOUSE_DOWN:
		app.pointer = {e.mouse_x, e.mouse_y}
		if d := divider_at(e.mouse_x, e.mouse_y); d >= 0 && e.mouse_button == .LEFT {
			divider_press(d, e.mouse_x, app.clicks)
			return
		}
		in_drawer := state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y)
		if mt != nil && in_pane(mt, e.mouse_x, e.mouse_y) && !in_drawer {
			// a click in the current tab takes the keyboard back; a sliding
			// (unpinned) drawer goes away
			if state.home_open && !state.layout.drawer_pinned do ui_do(core.Set_Home{open = false})
			else if state.focus_widget == "agent_input" do ui_do(core.Set_Focus{""})
			if term_link_mouse_down(mt, e) do return // ⌘-click or right-click on a link (term_links.odin)
			term_mouse_down(mt, e, app.clicks)
			return
		}
		clay.SetPointerState(app.pointer, true)
		hit := ui_hit()
		// right click (or ⌃-click): a row's context menu; nothing else
		if e.mouse_button == .RIGHT || (e.mouse_button == .LEFT && e.modifiers & sapp.MODIFIER_CTRL != 0) {
			clay.SetPointerState(app.pointer, false)
			if b, ok := hit.(Hit_Button); ok && Button(b) == .New_Tab do button_click(.New_Menu) // "+": its menu
			else if tb, ok1 := hit.(Hit_Tab); ok1 do tab_context(u64(tb), app.pointer) // ui_panes.odin
			else if j, ok2 := hit.(Hit_Jobs); ok2 do jobs_context(j, app.pointer)
			else do sidebar_context(hit, app.pointer)
			return
		}
		// the top bar is the title bar: its empty parts move the window, and
		// a double-click zooms (or what the user set in System Settings)
		if hit == nil && e.mouse_y < px(TAB_STRIP_H) {
			clay.SetPointerState(app.pointer, false)
			if app.clicks == 2 do window_titlebar_double_click()
			else if app.clicks == 1 do window_drag()
			return
		}
		switch hit in hit {
		case Hit_Project:   project_row_click(u64(hit)) // select and expand; again: fold
		case Hit_Session:   ui_do(core.Open_Session_Cmd{state.selected_project, string(hit)})
		case Hit_New:       new_session_ui(state.selected_project, at = [2]f32{e.mouse_x, e.mouse_y}) // the harness picker (harness.odin)
		case Hit_Tab:
			ui_do(core.Focus_Tab{u64(hit)})
			tab_drag_arm(u64(hit), e.mouse_x, e.mouse_y) // moved a few px, it drags (panes_drag.odin)
			// a double-click keeps a preview tab
			if _, t, _ := find_tab(u64(hit)); t != nil && app.clicks == 2 {
				if et, is := t.kind.(core.Editor_Tab); is && et.preview do ui_do(core.Keep_Tab{tab_id = t.id})
			}
		case Hit_Close_Tab: close_tab_click(u64(hit))
		case Hit_Confirm:   if bar_click_ok(string(hit)) do confirm_pending(string(hit))
		case Hit_Cancel:    if bar_click_ok(string(hit)) do cancel_pending(string(hit))
		case Hit_Panel_Head: ui_do(core.Set_Panel_Collapsed{panel = string(hit), collapsed = !core.panel_collapsed(string(hit))})
		case Hit_Palette_Row: // only while the palette has focus (widget_event)
		case Hit_Home:      ui_do(core.Set_Home{open = !state.home_open})
		case Hit_Close_Session: ui_do(core.Close_Session{session = u64(hit)})
		case Hit_Chat, Hit_Open_Row, Hit_Pin_Project, Hit_Pin_Session, Hit_New_In, Hit_Add_Project, Hit_Sort, Hit_Fold, Hit_Filter, Hit_Filter_Clear, Hit_Quick, Hit_Waiting_Filtered, Hit_More_Project, Hit_More_Session, Hit_More_Open, Hit_Show_More, Hit_Group, Hit_Kids, Hit_Info_Session, Hit_New_Job_In, Hit_Machine, Hit_Machine_Head, Hit_Machine_More, Hit_Machine_Add, Hit_Attention:
			sidebar_click(hit, app.pointer)
		case Hit_Agent:     drawer_click(hit)
		case Hit_Files: // files_event took it
		case Hit_Reload:    reload_click(hit) // the hot-reload bars
		case Hit_Claude_Reload: claude_reload_click(hit) // Claude Code's (ui_claude_reload.odin)
		case Hit_Dead_Tab:  dead_tab_click(fp, hit) // a dead pi tab's Restart (dead_tab.odin)
		case Hit_Update:    update_click(hit) // the update bar (ui_update.odin)
		case Hit_Comments:  comments_click(hit) // pending comments (ui_comments.odin)
		case Hit_Claude:    claude_click(fp, hit) // a Claude tab's held messages (ui_claude.odin)
		case Hit_Pane_New:  pane_click(hit) // a pane strip's "+" (ui_panes.odin)
		case Hit_Pane_Zoom: pane_zoom_click(hit) // the zoomed pane's "⤢ 1 of 3": restore
		case Hit_Pane_Divider: // pane_divider_press took it
		case Hit_Jobs:      jobs_click(hit)
		case Hit_Button:    button_click(Button(hit))
		case Hit_Fleet_Row: fleet_go(u64(hit)) // as ⌥⌘A would go there (ui_fleet.odin)
		case Hit_Peek_Row:  peek_open_session(u64(hit)) // a row's eye: Peek (ui_peek.odin)
		case Hit_Peek: // peek_event takes the panel's clicks first
		case Hit_Deck_Card, Hit_Deck_More: deck_click(hit, app.pointer) // (deck_event takes them first)
		case Hit_Menu_Row, Hit_Divider, Hit_Pop, Hit_Sheet_Close, Hit_Setup, Hit_Job_Sheet, Hit_Editor_Tool, Hit_Bell, Hit_Changes: // menu_event, the divider, the popover, the sheet and the editor take these first
		}
		clay.SetPointerState(app.pointer, false)
		app.redraw = true
	case .MOUSE_UP:
		if mt != nil do term_mouse_up(mt, e)
	case .MOUSE_MOVE:
		app.pointer = {e.mouse_x, e.mouse_y}
		if d := divider_at(e.mouse_x, e.mouse_y); d >= 0 && e.modifiers & sapp.MODIFIER_LMB == 0 {
			set_hover(Hit_Divider(d), false)
			return
		}
		if split := pane_divider_at(e.mouse_x, e.mouse_y); split != 0 && e.modifiers & sapp.MODIFIER_LMB == 0 && !over_overlay() {
			set_hover(Hit_Pane_Divider(split), false)
			return
		}
		in_term := (mt != nil && in_pane(mt, e.mouse_x, e.mouse_y) && !(state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y))) || editor_text_hit(pane_editor(fp), e.mouse_x, e.mouse_y)
		set_hover(in_term ? nil : chrome_hit(app.pointer), in_term)
		markdown_hover(e.mouse_x, e.mouse_y) // a link under the pointer (markdown_view.odin)
		// ⌘ held over a terminal's link: underlined, a hand and its URL (term_links.odin)
		term_links_frame()
		if mt != nil do term_mouse_move(mt, e)
	case .MOUSE_LEAVE:
		set_hover(nil, false)
	case .MOUSE_SCROLL:
		if over_sidebar(e.mouse_x) || over_right_column(e.mouse_x) {
			clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
			clay.UpdateScrollContainers(false, {e.scroll_x, e.scroll_y} * SCROLL_STEP * app.dpi, 1.0 / 60)
			app.redraw = true
		} else if mt != nil {
			term_scroll(mt, e)
		}
	case .RESIZED, .RESTORED, .RESUMED:
		app.redraw = true
	case .FOCUSED:
		app.window_active = true
		// the session on screen is seen now: its bell entries are read
		if core.notify_wants_seen(state.current_session) do client_internal(core.Notifications_Mark_Read{session = state.current_session})
		for id in core.status_wants_seen() do client_internal(core.Set_Unread{tab_id = id, unread = false}) // agent_status.odin
		if kt != nil do term_focus(kt, true)
	case .UNFOCUSED:
		app.window_active = false
		for _, x in term_views {
			term_cancel_drag(x) // its release may go to another app
			term_link_clear(x) // and ⌘'s
		}
		if kt != nil do term_focus(kt, false)
	case .QUIT_REQUESTED:
		// a separate core: the window closes, the core and its sessions run on (quit_route)
		if client_separate() {
			app.close_asked = {}
			if !core.app_quitting && len(tab_views_unsaved_paths()) > 0 {
				sapp.cancel_quit()
				toast_show(client.lost ? "Save (⌘S) or close the files with unsaved changes first: Deckhand's background core is gone" : "Save or close the files with unsaved changes first: the window closes, the sessions run on", true)
				return
			}
			if !app_closing() do quit_notice_once()
			app.closing = true
			platform_hide_windows()
			if core.autotest_active do fmt.println("[autotest] quit: windows hidden")
			return
		}
		// window close / Cmd+Q from the menu: ask first if anything runs
		if !core.app_quitting {
			sapp.cancel_quit()
			ui_do(core.Quit{})
			return
		}
		// the window goes first: the handover can wait seconds (an upgrade in flight, the ack, the
		// snapshots), and nothing is drawn meanwhile
		core.core_loop_stop() // no tick from the timer during the handover's waits
		platform_hide_windows()
		if core.autotest_active do fmt.println("[autotest] quit: windows hidden")
		// keep_sessions: the holder keeps the held tabs (snapshots and handover.json first);
		// otherwise they are released as direct ones are hung up
		if core.app_stop_sessions do core.holder_shutdown()
		else do core.holder_handover()
		core.relaunch_helper_send("") // an update's helper without a secret (none was handed over): it only relaunches
		core.persist_quit() // while the shells still run (their cwd is saved; held ids with a handover)
		core.close_all()
	}
}

// The confirmation bar's content as last drawn, and when it changed: a
// second click right after a Confirm/Cancel must not land on the next
// confirmation that slid into its place (a double-click).
BAR_GUARD :: 300 * time.Millisecond
bar_shown: string // token of the confirmation the bar showed in the last layout (owned)
bar_changed: time.Tick
bar_clicked: time.Tick

bar_layout_done :: proc() {
	tok := len(state.pending_confirmations) > 0 ? state.pending_confirmations[0].token : ""
	if tok == bar_shown do return
	delete(bar_shown)
	bar_shown = strings.clone(tok)
	bar_changed = time.tick_now()
}

bar_click_ok :: proc(token: string) -> bool {
	now := time.tick_now()
	defer bar_clicked = now
	// not what the user saw, or just replaced right after their last click
	if token != bar_shown do return false
	if bar_clicked != {} && time.tick_diff(bar_changed, now) < BAR_GUARD && time.tick_diff(bar_clicked, bar_changed) < BAR_GUARD do return false // the change came from that click
	return true
}

// Pane p's tab at its draw rect; IME marked text when its terminal (t) has the keyboard.
pane_draw :: proc(p: ^core.Pane, t: ^Term_View, typing: bool) {
	tab := core.pane_tab(core.cur_view(), p) // another machine's: only its terminals draw (no editor, page or app of it here)
	if tab == nil || (!tab.has_term && editor_of(tab.id) == nil && browser_of(tab.id) == nil && app_of(tab.id) == nil) do return
	r := pane_draw_rect(p)
	if r.z <= 0 || r.w <= 0 do return
	v := tab_view(tab.kind) // nil: a kind this window does not know (a newer core's; nothing to draw)
	if v == nil || v.draw == nil do return
	v.draw(tab.id, r.x, r.y, r.z, r.w)
	if pt := term_view_peek(tab.id); pt != nil && pt == t && typing do term_draw_marked(pt, ime.marked, ime.caret)
}

// Hit under the pointer from the last layout (no click).
chrome_hit :: proc(p: [2]f32) -> Hit {
	clay.SetPointerState(p, false)
	return ui_hit()
}

// Hover state for the chrome: redraw only when it changes; pointer shape follows.
set_hover :: proc(h: Hit, over_terminal: bool) {
	cursor := over_terminal ? sapp.Mouse_Cursor.IBEAM : (h != nil && !hit_inert(h) ? .POINTING_HAND : .DEFAULT)
	if _, is := h.(Hit_Divider); is do cursor = .RESIZE_EW
	if d, is := h.(Hit_Pane_Divider); is do cursor = pane_divider_across(u64(d)) ? .RESIZE_EW : .RESIZE_NS
	if sapp.get_mouse_cursor() != cursor do sapp.set_mouse_cursor(cursor)
	if h == ui_hover do return
	// own copies: session ids and tokens point into lists that get replaced
	#partial switch x in ui_hover {
	case Hit_Session: delete(string(x))
	case Hit_Chat:    delete(string(x))
	case Hit_Pin_Session: delete(string(x))
	case Hit_Confirm: delete(string(x))
	case Hit_Cancel:  delete(string(x))
	case Hit_Panel_Head: delete(string(x))
	case Hit_More_Session: delete(string(x))
	case Hit_Info_Session: delete(string(x))
	}
	ui_hover = h
	tip_hover_changed()
	#partial switch x in h {
	case Hit_Session: ui_hover = Hit_Session(strings.clone(string(x)))
	case Hit_Chat:    ui_hover = Hit_Chat(strings.clone(string(x)))
	case Hit_Pin_Session: ui_hover = Hit_Pin_Session(strings.clone(string(x)))
	case Hit_Confirm: ui_hover = Hit_Confirm(strings.clone(string(x)))
	case Hit_Cancel:  ui_hover = Hit_Cancel(strings.clone(string(x)))
	case Hit_Panel_Head: ui_hover = Hit_Panel_Head(strings.clone(string(x)))
	case Hit_More_Session: ui_hover = Hit_More_Session(strings.clone(string(x)))
	case Hit_Info_Session: ui_hover = Hit_Info_Session(strings.clone(string(x)))
	}
	app.redraw = true
}

// The user confirmed a pending command: resend it with its token.
confirm_pending :: proc(token: string) {
	// TODO(M6-D/E): another machine's confirmations asked here (machine_route.odin) re-send the
	// user's command with its token; a type missing below (or Changes_Discard's second question)
	// can't be confirmed from here. Not reachable yet: only terminal tabs' commands reach one.
	for p in state.pending_confirmations {
		if p.token != token do continue
		// a command this window cannot decode (a newer core's: the replica holds nil) is never
		// confirmed blind; Cancel still works
		if p.command == nil {
			toast_show("This needs a newer Deckhand to confirm: cancel it, or confirm it there", true)
			return
		}
		cmd := p.command
		#partial switch c in p.command {
		case core.Close_Tab: cmd = core.Close_Tab{tab_id = c.tab_id, confirm = token, comments = c.comments}
		case core.Close_Session: cmd = core.Close_Session{session = c.session, confirm = token, ask = c.ask, comments = c.comments}
		case core.Quit:      cmd = core.Quit{confirm = token, stop_sessions = c.stop_sessions}
		case core.Update_Install: cmd = core.Update_Install{confirm = token}
		case core.Pi_Reload: cmd = core.Pi_Reload{tab_id = c.tab_id, confirm = token}
		case core.Pi_Reload_All: cmd = core.Pi_Reload_All{only_changed = c.only_changed, confirm = token}
		case core.Pi_Restart_Updated: cmd = core.Pi_Restart_Updated{confirm = token}
		case core.Claude_Restart_Changed: cmd = core.Claude_Restart_Changed{update = c.update, all = c.all, confirm = token}
		case core.Reload_File: cmd = core.Reload_File{tab_id = c.tab_id, confirm = token}
		case core.Delete_Path: cmd = core.Delete_Path{path = c.path, confirm = token}
		case core.Create_File: cmd = core.Create_File{path = c.path, confirm = token}
		case core.Create_Dir:  cmd = core.Create_Dir{path = c.path, confirm = token}
		case core.Rename_Path: cmd = core.Rename_Path{from = c.from, to = c.to, confirm = token}
		case core.Worktree_Cleanup: cmd = core.Worktree_Cleanup{path = c.path, confirm = token}
		case core.Job_Delete:  cmd = core.Job_Delete{job = c.job, confirm = token}
		case core.Changes_Discard: cmd = core.Changes_Discard{tab_id = c.tab_id, path = c.path, status = c.status, second = c.second, confirm = token}
		case core.Markdown_Follow: cmd = core.Markdown_Follow{tab_id = c.tab_id, url = c.url, confirm = token}
		case core.Set_Claude_Default_Flags: cmd = core.Set_Claude_Default_Flags{skip_permissions = c.skip_permissions, confirm = token}
		case core.Machine_Remove: cmd = core.Machine_Remove{no = c.no, confirm = token}
		case core.Set_Machines_Reachable: cmd = core.Set_Machines_Reachable{on = c.on, confirm = token}
		}
		if p.caller.kind == .UI && !p.caller.hub do closed_tab_answered(p.command, true) // the user's own close: ⇧⌘T (closed_tabs.odin)
		ui_do(cmd)
		return
	}
}

// Input for the focused widget (a text field: the rename field or the
// palette's query). True if consumed.
widget_event :: proc(e: ^sapp.Event) -> bool {
	f, text_id, box_id := focused_field()
	if f == nil do return false
	in_palette := state.focus_widget == "palette"
	in_filter := state.focus_widget == "sidebar_filter"
	in_files_filter := state.focus_widget == "files_filter"
	in_files_name := state.focus_widget == "files_name"
	shift := e.modifiers & sapp.MODIFIER_SHIFT != 0
	cmd := e.modifiers & sapp.MODIFIER_SUPER != 0
	alt := e.modifiers & sapp.MODIFIER_ALT != 0
	ctrl := e.modifiers & sapp.MODIFIER_CTRL != 0
	before := strings.clone(tf_text(f), context.temp_allocator)
	defer {
		// a changed query starts over at the best match
		if in_palette && tf_text(f) != before do palette_edited()
		// the filter is State: every edit is a set_filter (agents see it too)
		if in_filter && state.focus_widget == "sidebar_filter" && tf_text(f) != before do ui_do(core.Set_Filter{text = tf_text(f)})
		if in_files_filter && state.focus_widget == "files_filter" && tf_text(f) != before do ui_do(core.Set_Files_Filter{text = tf_text(f)})
		if in_filter && tf_text(f) != before do attention_keyed = false // typed in: Space is a space again
		platform_ime_caret_moved()
	}
	#partial switch e.type {
	case .KEY_DOWN:
		app.redraw = true
		if cmd {
			#partial switch e.key_code {
			case .A: // ⌘A alone; ⌥⌘A ⌥⇧⌘A: next, previous needing you (menubar.odin)
				if alt do return false
				if !ctrl do tf_select_all(f)
			case .PERIOD: if alt do return false // ⌥⌘.: the Attention view (menubar.odin)
			case .C: if s := tf_selected_text(f); s != "" do clipboard_set(s)
			case .X:
				if s := tf_selected_text(f); s != "" {
					clipboard_set(s)
					tf_backspace(f)
				}
			case .LEFT, .UP:     tf_home(f, shift)
			case .RIGHT, .DOWN:  tf_end(f, shift)
			case .BACKSPACE:     tf_delete_to_start(f)
			case ._1 ..= ._9, .GRAVE_ACCENT: // ⌥⌘1–⌥⌘6, ⌥⌘` ⌥⇧⌘`: sessions (menubar.odin)
				if alt do return false
				if in_palette && e.key_code != .GRAVE_ACCENT do palette_run_index(palette.first + int(e.key_code) - int(sapp.Keycode._1))
			case .Q:             ui_do(core.Quit{})
			}
			return true
		}
		if in_files_filter && files_filter_key(e.key_code) do return true
		if in_files_name {
			#partial switch e.key_code {
			case .ENTER, .KP_ENTER:
				files_commit_edit()
				return true
			case .ESCAPE:
				files_cancel_edit()
				return true
			}
		}
		#partial switch e.key_code {
		case .ENTER, .KP_ENTER:
			if in_palette {
				palette_run_index(palette.selected)
			} else if in_filter {
				filter_enter()
			} else if state.focus_widget == "rename_session" {
				ui_do(core.Claude_Rename{claude_session_id = rename_session, title = tf_text(f)}) // a Claude row (claude.odin)
				ui_do(core.Set_Focus{""})
			} else {
				ui_do(core.Rename_Project{state.selected_project, tf_text(f)})
				ui_do(core.Set_Focus{""})
			}
		case .ESCAPE:
			if in_filter do ui_do(core.Set_Filter{text = ""}) // Esc clears the filter
			ui_do(core.Set_Focus{""})
		case .BACKSPACE: if alt do tf_delete_word_left(f); else do tf_backspace(f)
		case .DELETE:    tf_delete(f)
		case .LEFT:      if alt do tf_word_left(f, shift); else do tf_move(f, -1, shift)
		case .RIGHT:     if alt do tf_word_right(f, shift); else do tf_move(f, 1, shift)
		case .HOME:      tf_home(f, shift)
		case .END:       tf_end(f, shift)
		case .UP:
			if in_palette do palette_move(-1)
			else if !(in_filter && attention_step(-1)) do tf_home(f, shift) // the Attention view's rows (ui_sidebar.odin)
		case .DOWN:
			if in_palette do palette_move(1)
			else if !(in_filter && attention_step(1)) do tf_end(f, shift)
		case .SPACE: // the Attention view's keyboard row: Peek (ui_peek.odin); else a space (its CHAR)
			if in_filter && attention_peek_key() do app.key_taken = true
		case .PAGE_UP:   if in_palette do palette_move(-PALETTE_ROWS)
		case .PAGE_DOWN: if in_palette do palette_move(PALETTE_ROWS)
		case .TAB:       if in_palette do palette_move(shift ? -1 : 1)
		}
		return true
	case .KEY_UP:
		return true
	case .CHAR:
		if !cmd && e.char_code >= 0x20 && e.char_code != 0x7f {
			if r, ok := utf16_unit(&app_surrogate, e.char_code); ok {
				tf_insert(f, utf8_string(r))
				app.redraw = true
			}
		}
		return true
	case .CLIPBOARD_PASTED:
		tf_insert(f, clipboard_text())
		app.redraw = true
		return true
	case .MOUSE_DOWN:
		app.redraw = true
		if in_palette {
			clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
			if hit, ok := ui_hit().(Hit_Palette_Row); ok {
				palette_run_index(int(hit))
				return true
			}
			if !inside(clay.ID("palette_box"), e.mouse_x, e.mouse_y) {
				ui_do(core.Set_Focus{""}) // a click outside closes it (and does nothing else)
				return true
			}
			if !field_inside(box_id, e.mouse_x, e.mouse_y) do return true
		} else if !field_inside(box_id, e.mouse_x, e.mouse_y) {
			// a click outside the field ends editing (and is handled normally)
			ime_cancel()
			ui_do(core.Set_Focus{""})
			return false
		}
		if ime.marked != "" do return true // the input method owns the caret
		off := field_offset_at(f, text_id, e.mouse_x)
		tf_click(f, off, app.clicks, shift)
		app.field_drag = true
		return true
	case .MOUSE_MOVE:
		if app.field_drag && e.modifiers & sapp.MODIFIER_LMB != 0 {
			tf_drag(f, field_offset_at(f, text_id, e.mouse_x))
			app.redraw = true
			return true
		}
		app.field_drag = false
		if in_palette {
			clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
			set_hover(ui_hit(), false)
			return true
		}
	case .MOUSE_UP:
		if app.field_drag {
			app.field_drag = false
			return true
		}
	case .MOUSE_SCROLL:
		if in_palette {
			palette.first = clamp(palette.first - int(e.scroll_y), 0, max(len(palette_results()) - PALETTE_ROWS, 0))
			app.redraw = true
			return true
		}
	}
	return false
}

inside :: proc(id: clay.ElementId, x, y: f32) -> bool {
	d := clay.GetElementData(id)
	b := d.boundingBox
	return d.found && x >= b.x && x < b.x + b.width && y >= b.y && y < b.y + b.height
}

// Counts presses at about the same place within the system's double-click
// interval: 1, 2 (word), 3 (line), ...
count_click :: proc(x, y: f32) {
	now := time.tick_now()
	near := abs(x - app.last_click_at.x) <= px(SP_1) && abs(y - app.last_click_at.y) <= px(SP_1)
	quick := app.last_click != {} && time.duration_seconds(time.tick_diff(app.last_click, now)) <= platform_double_click_interval()
	app.clicks = near && quick ? app.clicks + 1 : 1
	app.last_click, app.last_click_at = now, {x, y}
}

// CHAR events carry UTF-16 units: pairs of surrogates make one character.
app_surrogate: u32

utf16_unit :: proc(pending: ^u32, cp: u32) -> (rune, bool) {
	if cp >= 0xD800 && cp < 0xDC00 {
		pending^ = cp
		return 0, false
	}
	if cp >= 0xDC00 && cp < 0xE000 {
		if pending^ == 0 do return 0, false
		r := rune(0x10000 + ((pending^ - 0xD800) << 10) + (cp - 0xDC00))
		pending^ = 0
		return r, true
	}
	pending^ = 0
	return rune(cp), true
}

// ---- input methods (platform_darwin.odin calls these) ----

// The input method committed text: into the focused field, else typed into
// the current terminal as UTF-8.
ime_commit :: proc(text: string) {
	if !autotest_allows_input() do return
	ime_set_marked("", 0)
	if peek_is_open() { 	// a peek is for looking: the text goes nowhere (ui_peek.odin)
	} else if f, _, _ := focused_field(); f != nil {
		tf_insert(f, text)
		if state.focus_widget == "palette" do palette_edited()
		if state.focus_widget == "sidebar_filter" do attention_keyed = false // typed in: Space is a space again (ui_peek.odin)
	} else if t := key_view(); t != nil {
		core.claude_note_typed(core.key_tab())
		term_text_input(t, text)
	} else if ed := active_editor(); ed != nil {
		editor_ime_commit(ed, text)
	}
	app.redraw = true
}

ime_set_marked :: proc(text: string, caret: int) {
	if !autotest_allows_input() do return
	if text != "" && peek_is_open() { 	// a peek takes no text: no composition, here or in the platform (ui_peek.odin)
		ime_os_cancel()
		return
	}
	if text == ime.marked do return
	delete(ime.marked)
	ime.marked = strings.clone(text)
	ime.caret = caret
	app.redraw = true
	if t := key_view(); t != nil do t.changed = true
}

ime_cancel :: proc() {
	if ime.marked == "" do return
	ime_os_cancel()
	ime_set_marked("", 0)
}

// The platform's input method drops its composition.
ime_os_cancel :: proc() {
	ime.os_cancels += 1
	platform_ime_cancel()
}

// Option starts dead keys (é, ü) in text fields; in a terminal it is Alt.
ime_option_composes :: proc() -> bool {return state.focus_widget != "" || active_editor() != nil}

// The candidate window's anchor: the field caret, else the terminal cursor.
ime_anchor :: proc() -> [4]f32 {
	if state.focus_widget == "" {
		if t := key_view(); t != nil do return {t.cursor_px.x, t.cursor_px.y, font.cell_w, font.cell_h}
	}
	return ime.caret_rect // a field's caret, or the editor's (editor_draw)
}

// Window title (hidden in the title bar; Mission Control, the Window menu
// and ⌘` show it): the current session's title.
update_window_title :: proc() {
	title := "Deckhand"
	if cs := core.cur_view(); cs != nil {
		_, place := core.session_place(cs)
		title = fmt.tprintf("%s · %s — Deckhand", place, core.open_session_title(cs))
		if cs.machine != 0 do title = fmt.tprintf("%s · %s", core.machine_name(cs.machine), title) // another machine's session
	}
	if title == app.window_title do return
	delete(app.window_title)
	app.window_title = strings.clone(title)
	sapp.set_window_title(strings.clone_to_cstring(title, context.temp_allocator))
}

utf8_string :: proc(r: rune) -> string {
	b, n := utf8.encode_rune(r)
	return strings.clone(string(b[:n]), context.temp_allocator)
}

cleanup :: proc "c" () {
	context = core.app_context
	if client_separate() { // the core's things are the core process's
		cw.sock_flush(client.sock)
		browser_shutdown()
		app_shutdown()
		comments_draft_shutdown()
		sgl.shutdown()
		sg.shutdown()
		if autotest.failures > 0 do os.exit(1)
		return
	}
	core.core_loop_stop()
	core.login_env_kill_probe() // a refresh's shell still running (login_env.odin)
	core.harness_no_sudo_sweep(at_quit = true) // a run's no-sudo folder (harness_install.odin)
	core.persist_quit()
	core.titles_save()
	core.socket_stop()
	core.jobs_shutdown()
	core.close_all()
	core.holder_client_stop() // the session holder's connection (holder_client.odin)
	browser_shutdown() // CEF before sokol (browser.odin)
	app_shutdown() // app tabs' processes (app_tab.odin)
	core.comments_shutdown() // this run's crops (comments.odin)
	comments_draft_shutdown() // and the comment bar's (ui_comments.odin)
	sgl.shutdown()
	sg.shutdown()
	if autotest.failures > 0 do os.exit(1)
}

// Command line, checked before any window opens.
App_Args :: struct {
	dir:        string,
	token_kind: string, // "script" | "control" | ""
	fresh:      bool, // --fresh: do not restore the saved workspace
	claude:     bool, // --claude DIR: a Claude session there instead of a pi chat
}
app_args: App_Args

when core.TEST_HOOKS {
	APP_USAGE :: "usage: deckhand [--fresh] [--print-token script|control] [--claude] [DIR]   |   deckhand --ctl [--wait MS] JSON..."
	PRINT_TOKEN_FLAG :: "--print-token"
} else {
	APP_USAGE :: "usage: deckhand [--fresh] [--claude] [DIR]   |   deckhand --ctl [--wait MS] JSON..."
	PRINT_TOKEN_FLAG :: "" // never matches: a release build has no --print-token (test_hooks.odin)
}

// The command line (after the program's name; --ctl is handled before). --claude needs DIR.
app_args_parse :: proc(args: []string) -> (a: App_Args, ok: bool) {
	for i := 0; i < len(args); i += 1 {
		x := args[i]
		if PRINT_TOKEN_FLAG != "" && x == PRINT_TOKEN_FLAG && i + 1 < len(args) && (args[i + 1] == "script" || args[i + 1] == "control") {
			a.token_kind = args[i + 1]
			i += 1
		} else if x == "--fresh" {
			a.fresh = true
		} else if x == "--claude" {
			a.claude = true
		} else if strings.has_prefix(x, "-") || a.dir != "" {
			return {}, false
		} else do a.dir = x
	}
	if a.claude && a.dir == "" do return {}, false
	return a, true
}

// The project `deckhand DIR` starts in: the one Add_Project made or selected for DIR; 0 = none.
launch_project :: proc(r: core.Result) -> u64 {
	return r.ok ? r.created_id : 0
}

// What `deckhand DIR` starts in project pid once the pane has a size: a pi chat (a Claude session when
// Claude Code is the only harness installed), or with --claude a
// Claude session (the user's own launch: it comes to the front; without Claude Code a toast says
// how to install it).
launch_start :: proc(claude: bool, pid: u64) -> core.Command {
	if pid == 0 || core.find_project(pid) == nil do return nil // never the project that happened to be selected
	if claude do return core.New_Claude_Session{project_id = pid}
	if !core.pi_installed() && core.claude_installed() do return core.New_Claude_Session{project_id = pid} // Claude Code alone (harness.odin)
	return core.New_Chat{pid}
}

// Test mode's backing scale from DECKHAND_SCALE (docs/DEVELOPING.md "Test mode"): unset or empty
// is 1, so a scene's pixels are the same on every Mac; else a number from 1 to 4.
test_scale_parse :: proc(env: string) -> (scale: f64, ok: bool) {
	s := strings.trim_space(env)
	if s == "" do return 1, true
	v, parsed := strconv.parse_f64(s)
	if !parsed || !(v >= 1 && v <= 4) do return 0, false // NaN fails both
	return v, true
}

main :: proc() {
	core.persist.launch = time.tick_now()
	if len(os.args) > 1 && os.args[1] == "--ctl" {
		ctl_core_ensure() // a separate core that went: launched again (client_core.odin)
		os.exit(core.ctl_main(os.args[2:]))
	}
	ok: bool
	app_args, ok = app_args_parse(os.args[1:])
	if !ok {
		fmt.eprintln(APP_USAGE)
		os.exit(2)
	}
	core.app_context = context
	// from the Dock or Finder: the login shell's environment, before any thread (login_env.odin)
	core.login_env_startup()
	when core.TEST_HOOKS {
		// test mode is quiet unless DECKHAND_QUIET=0: the window never shows or takes focus
		if core.hook_env(.Script) != "" && core.hook_env(.Quiet) != "0" do platform_quiet()
		// test mode: the same backing scale on every Mac (DECKHAND_SCALE, default 1), quiet or not
		if core.hook_env(.Script) != "" {
			scale, sok := test_scale_parse(core.hook_env(.Scale))
			if !sok {
				fmt.eprintln("Deckhand: DECKHAND_SCALE must be a number from 1 to 4 (test mode's backing scale; unset = 1)")
				os.exit(2)
			}
			platform_test_scale(scale)
		}
	}
	platform_display_hook() // sokol's display link: the window's screen's rate (platform_macos.m)
	sapp.run({
		init_cb = init,
		frame_cb = frame,
		event_cb = event_os,
		cleanup_cb = cleanup,
		width = 1400,
		height = 860,
		high_dpi = true,
		window_title = "Deckhand",
		enable_clipboard = true,
		enable_dragndrop = true, // folders dropped on the window become projects
		max_dropped_files = 16,
		max_dropped_file_path_length = 4096,
		clipboard_size = 4 * 1024 * 1024,
		logger = {func = slog.func},
	})
}

// A session holder from another build runs (state.holder_ask, core holder_client.odin): asked
// once, outside any frame's drawing. Test mode never shows the modal: it logs the question, and
// the script answers with holder_replace.
@(private = "file")
holder_asked: i32

@(private = "file")
holder_ask_tick :: proc() {
	ask := state.holder_ask
	if ask.pid == 0 || ask.pid == holder_asked do return
	holder_asked = ask.pid
	text := fmt.tprintf("A session holder from another build is running (%d session%s). Stop it and start a new one?", ask.sessions, ask.sessions == 1 ? "" : "s")
	if core.autotest_active {
		fmt.println("[autotest] holder ask:", text)
		return
	}
	stop := platform_ask("Another session holder is running", fmt.tprintf("%s\n\nStopping it ends its sessions. Otherwise Deckhand runs without one: tabs opened now stop when Deckhand quits.", text), "Stop It and Start a New One", "Keep It Running")
	client_send(core.Holder_Replace{stop = stop})
}

// The user cancelled a pending command (the bar's Cancel).
cancel_pending :: proc(token: string) {
	for p in state.pending_confirmations do if p.token == token && p.caller.kind == .UI && !p.caller.hub do closed_tab_answered(p.command, false) // closed_tabs.odin
	ui_do(core.Cancel_Confirmation{token})
}
