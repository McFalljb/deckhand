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
	font_theme:     Theme_Id, // the look the fonts were opened for
	font_size:      Text_Size, // and the text size
	// clicks: count of the current multi-click (1, 2, 3, ...)
	clicks:         int,
	last_click:     time.Tick,
	last_click_at:  [2]f32,
	field_drag:     bool, // a press in the focused field: moves extend its selection
	key_in_widget:  bool, // the last KEY_DOWN went to a widget
	key_taken:      bool, // the last KEY_DOWN was the chrome's: drop its CHAR/KEY_UP
	window_active:  bool, // the window has the keyboard (sokol FOCUSED/UNFOCUSED)
	window_title:   string,
}

// An input method's composition (dead key, IME), shown at the caret of the
// focused field or the terminal cursor until committed. UI state.
Ime :: struct {
	marked:     string, // "" = none (heap)
	caret:      int, // byte offset in marked
	caret_rect: [4]f32, // last drawn caret (framebuffer px): the candidate window goes under it
}
ime: Ime

app: App

init :: proc "c" () {
	context = app_context
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
	platform = platform_app()
	app.window_active = true
	platform_window_init()
	menubar_install() // the macOS menu bar (menubar.odin)
	// the OS appearance before anything is drawn, then its changes
	run_command(System_Appearance{light = platform_system_light()})
	platform_watch_appearance()
	autotest_init()
	if autotest_active do platform.notify = proc(title, body: string) {fmt.println("[autotest] notify:", title, "-", body)}
	// test mode keeps its log out of the user's data dir
	if autotest_active && hook_env(.Data_Dir) == "" {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		home_root = strings.concatenate({cwd, "/build/test-data"}) // absolute: Home's pi runs elsewhere
	} else do home_root = data_dir()
	if home_root == "" {
		// no home for this account in the user database (a release build never takes $HOME):
		// never a data dir relative to wherever Deckhand was started
		why := "Deckhand can't find your home folder (your account has no entry in the user database), so it has nowhere to keep its files"
		fmt.eprintln("Deckhand:", why)
		platform_alert("Deckhand can't start", why)
		os.exit(1)
	}
	// one Deckhand per data dir, and none beside a running pi-desk 0.1.x (instance.odin), before
	// anything is written there; test mode looks for Deckhand only in a runtime dir of its own
	check_old := !autotest_active || hook_env(.Runtime_Dir) != ""
	if why := instance_guard(home_root, check_old); why != "" {
		if autotest_active {
			fmt.println("[autotest] instance refused:", why)
			os.exit(3)
		}
		fmt.eprintln("Deckhand:", why)
		platform_alert("Deckhand can't start", why)
		os.exit(1)
	}
	event_log_open(home_root)
	// Atlas's prompt (an unedited older starter) and its copy of the guide (agent.odin)
	if home_root != "" {
		y, m, d := time.date(time.now())
		agent_prompt_migrate(fmt.tprintf("%04d-%02d-%02d", y, int(m), d))
		agent_guide_install()
	}
	// the session-title cache (titles.odin): same rule as the workspace
	if !autotest_active || hook_env(.Data_Dir) != "" do titles_load(data_dir(context.temp_allocator))
	claude_accounts_refresh() // Claude Code's config folders (claude_accounts.odin)
	rescan_now(claude = false) // pi's projects now; Claude's after the saved accounts are back
	// control socket (socket.odin); `--print-token script|control` mints a
	// token for local scripts and prints it once, as shell exports
	// (development and test builds only: a release build mints a control token only from
	// Settings › Copy a control token, test_hooks.odin)
	dir, token_kind := app_args.dir, app_args.token_kind
	if socket_start() && token_kind != "" {
		when TEST_HOOKS {
			kind := token_kind == "control" ? Caller_Kind.Control : Caller_Kind.Script
			fmt.printf("export DECKHAND_SOCKET='%s' DECKHAND_TOKEN='%s'\n", socket_path(), socket_mint_token({kind = kind}, context.temp_allocator))
			os.flush(os.stdout)
		}
	}
	// the saved workspace (persist.odin); test mode only with an explicit
	// DECKHAND_DATA_DIR, so scripts never read or write the user's
	state.settings.keep_sessions = keep_sessions_default() // until the saved workspace says otherwise
	if !autotest_active || hook_env(.Data_Dir) != "" {
		persist_init(data_dir(context.temp_allocator))
		claude_disk_launching = true // no transcript read on the main thread while it comes back
		persist_load(app_args.fresh)
		claude_disk_launching = false
	}
	// the session holder: tabs whose processes it kept since the last run get them back now
	// (holder_adopt.odin); with keep_sessions on it is connected (or launched) here
	holder_adopt_all()
	harness_no_sudo_sweep(at_quit = false) // no-sudo folders of runs whose Deckhand is gone (harness_install.odin)
	// Claude's projects (claude_disk.odin), on the Rescan worker, with the saved accounts (added
	// ones in, removed ones out)
	if claude_startup_rescan_due() do run_command(Rescan{}, {kind = .Internal})
	// the chats folder's instructions (folders.odin), then the first-run sheet
	// once while no main folder is set (test mode: only when a scene asks)
	// (not while setup is due: Done writes it where the user puts chats)
	if (!autotest_active || hook_env(.Data_Dir) != "") && !setup_due() do chats_instructions_ensure(date_stamp())
	if setup_due() && (!autotest_active || hook_env(.First_Run) == "1") do run_command(Setup_Sheet{open = true})
	// `deckhand DIR` adds/selects DIR and starts a new chat there.
	if dir != "" {
		r := run_command(Add_Project{dir})
		// only in DIR's own project: a failed add starts nothing (never the one selected before)
		app.launch_project = launch_project(r)
		if app.launch_project != 0 do app.pending_start = true
		else do fmt.eprintfln("Deckhand: %s: %s", dir, r.error)
	}
	update_init() // Deckhand's own updates: saved choices, leftovers, the check timer (update.odin)
	app.ready = true
	app.redraw = true
}

// The app's platform layer: every entry set (a nil one would make its
// commands do nothing without a word).
platform_app :: proc() -> Platform {
	return {
		set_clipboard = proc(text: string) {sapp.set_clipboard_string(strings.clone_to_cstring(text, context.temp_allocator))},
		get_clipboard = proc() -> string {return string(sapp.get_clipboard_string())},
		quit = proc() {
			app_quitting = true
			sapp.request_quit()
		},
		wake = platform_wake,
		pick_folder = platform_pick_folder,
		run_later = platform_run_later,
		set_appearance = platform_set_appearance,
		reveal = platform_reveal,
		notify = platform_notify,
		window_active = proc() -> bool {return app.window_active},
		left_button = platform_left_button,
		open_url = platform_open_url,
		clipboard_count = platform_clipboard_count,
		set_clipboard_secret = platform_clipboard_set_secret,
		clear_clipboard_if = platform_clipboard_clear_if,
		trash = fs_trash, // editor_platform_*.odin
		activity = platform_activity,
	}
}

// The window's side of the core's hooks (window_hooks.odin), filled in before main runs so the
// unit tests have them too.
window_hooks_app :: proc() -> Window_Hooks {
	return {
		state_changed = proc() {app.redraw = true},
		toast = proc(text: string, err: bool) {toast_show(text, err)},
		frames_info = proc(tab_id: u64) -> (service: string, key: [32]u8, device: u64, ok: bool) {
			when ODIN_OS == .Darwin {
				if dh_frames_chan_key(tab_id, &key[0]) == 1 do return string(dh_frames_service()), key, dh_frames_device_id(), true
			}
			return
		},
		display = proc() -> (fps: int, scale: f32, ok: bool) {
			fps, scale = platform_display()
			return fps, scale, true
		},
		frames_read = proc(tab_id: u64, gen: u32, slot: int, x, y, w, h: int, dst: []u8) -> bool {
			when ODIN_OS == .Darwin {
				return dh_frames_read(tab_id, gen, c.int(slot), c.int(x), c.int(y), c.int(w), c.int(h), raw_data(dst)) != 0
			}
			return false
		},
		browser_json = proc(b: ^strings.Builder, tab_id: u64) {
			annot_tab_json(b, tab_id) // comment mode, markers (browser_annotate.odin)
			browser_polish_tab_json(b, tab_id) // zoom, bars, downloads (browser_polish.odin)
			browser_agent_tab_json(b, tab_id) // the agent strip (browser_agent.odin)
			browser_act_tab_json(b, tab_id) // an upload's ask (browser_act.odin)
		},
		browser_page = proc(tab_id: u64) -> string {
			b := browser_of(tab_id)
			if b == nil do return ""
			return b.cef != 0 ? "open" : b.waiting ? "waiting" : b.lazy ? "unloaded" : b.message != "" ? "closed" : "opening"
		},
		app_view = proc(tab_id: u64) -> (v: App_View, ok: bool) {
			a := app_of(tab_id)
			if a == nil do return
			v = {frames = a.ring.shown, inspect = a.inspect}
			if g := ring_gen(&a.ring, a.ring.cur_gen); g != nil do v.has_ring, v.ring_gen, v.ring_w, v.ring_h = true, g.gen, g.w, g.h
			return v, true
		},
		md_view = proc(tab_id: u64, source: bool) -> (line, links, headings, matches: int, ok: bool) {
			v := md_view_of(tab_id)
			if v == nil || !v.laid do return
			line, links, headings, matches = md_state_numbers(v, tab_id, source) // markdown_view.odin
			return line, links, headings, matches, true
		},
		tab_host_apply = tab_host_apply_app, // tabhost.odin
		test_step = autotest_step,
		test_event = autotest_on_event,
		// tab views (tab_views.odin)
		view_open = tab_view_open,
		view_goto = tab_view_goto,
		view_drop = tab_view_drop,
		view_moved = tab_view_moved,
		files_deleted = tab_views_files_deleted,
		changes_diff = tab_view_changes_diff,
		changes_rewind = tab_view_changes_rewind,
		commit_message_clear = proc() {tf_set(&changes_message_field, "")}, // ui_changes.odin
		unsaved_files = tab_views_unsaved,
		tab_dirty = tab_view_dirty,
		// terminals' views (term_view.odin)
		term_view_new = term_view_init,
		term_view_free = term_view_free,
		term_drag_cancel = term_cancel_drag,
		term_fit = proc(t: ^Term, tab_id: u64) {if r := tab_rect(tab_id); r.z > 0 do term_set_rect(t, r.x, r.y, r.z, r.w)},
		// sheets (ui_job_sheet.odin, ui_setup.odin)
		job_sheet = job_sheet_apply,
		job_sheet_open = job_sheet_open,
		job_sheet_holds_quit = job_sheet_holds_quit,
		job_sheet_saved = job_sheet_saved,
		setup_sheet = setup_sheet_op,
		setup_state = setup_state_now,
		dpi = proc() -> f32 {return app.dpi},
	}
}

@(init)
window_hooks_init :: proc "contextless" () {
	context = runtime.default_context()
	window = window_hooks_app()
}

// The OS switched between light and dark (platform layer, main thread; the
// test mode's `system_appearance` too).
on_system_appearance :: proc(light: bool) {
	inbox_submit(System_Appearance{light = light}, {kind = .Internal})
}

// UI actions go through the inbox like every other caller; event() drains it
// right after, so they apply in order before the next event.
ui_do :: proc(cmd: Command) {
	inbox_submit(cmd, {kind = .UI})
}

// A menu row's command: as ui_do, then its outcome is shown where nothing
// else would show it (menu_result: a failure, a copy).
ui_do_menu :: proc(cmd: Command, label: string) {
	inbox_submit(cmd, {kind = .UI}, menu = label)
}

frame :: proc "c" () {
	context = app_context
	defer free_all(context.temp_allocator)

	app_frames_called += 1
	core_tick() // inbox, the test step, terminals, persistence, jobs, Claude (core_loop.odin)
	editor_tick() // files changed on disk, git gutter (editor_watch.odin)
	browser_debug_tick() // DECKHAND_DEBUG_BROWSER (browser.odin, spike)
	t := active_term()
	// Output-driven redraws are capped near 60 Hz; input redraws at once.
	at := agent_term() // Atlas's terminal in the drawer (also while it slides out)
	drags_follow_focus()
	left_down := platform.left_button == nil || platform.left_button()
	if t != nil do term_drag_tick(t, left_down) // a selection dragged past the grid's edge scrolls
	if at != nil do term_drag_tick(at, left_down)
	shown_changed := false // a terminal in another pane on screen (panes.odin)
	for x in terms_on_screen() do if x != t && x.changed do shown_changed = true
	if ((t != nil && t.changed) || shown_changed || (at != nil && at.changed && drawer_laid_out)) && time.tick_since(app.last_draw) > OUTPUT_FRAME do app.redraw = true
	if ui_wants_frame() do app.redraw = true // a fade or a running dot is moving
	if tip_due() do app.redraw = true // the pointer rested on a control: one frame for its tooltip
	if toast_tick() do app.redraw = true // a menu choice's outcome went away (toast.odin)
	control_token_clip_tick() // Copy a control token: off the clipboard after a minute (commands.odin)
	holder_successor_retry_tick() // after REFUSED{secret}: attach again once the reservation lapsed (holder_client.odin)
	holder_upgrade_tick() // an older holder than the bundled one: upgraded once, after the adopt (holder_restart.odin)
	if holder_restart_tick() do app.redraw = true // Restart session holder's outcome (holder_restart.odin)
	if app_frames_tick() do app.redraw = true // app tabs: a frame arrived, an exit, a stall (app_tab.odin)
	dh_cef_pump_due() // CEF's pump when its timer is overdue (cef_macos.m)
	if browser_frames_tick() do app.redraw = true // browser tabs: a frame CEF painted (browser.odin)
	if browser_polish_pending_tick() do app.redraw = true // blocked popups held back a second (browser_polish.odin)
	if browser_agent_tick() do app.redraw = true // agents' reads, waits, screenshots, recordings (browser_agent.odin)
	if browser_act_tick() do app.redraw = true // agents' clicks, typing, uploads (browser_act.odin)
	app_focus_tick()
	if !app.redraw do return // nothing changed: keep the last frame on screen
	app.last_draw = time.tick_now()
	// moved to a display with another scale, set_theme picked another look,
	// set_text_size another size or set_terminal_text_size the terminals'
	if d := sapp.dpi_scale(); d != app.dpi || state.settings.theme != app.font_theme || state.settings.text_size != app.font_size || font_config.mono_pt != term_text_pt() {
		app.dpi = d
		app.font_theme = state.settings.theme
		app.font_size = state.settings.text_size
		fonts_apply(theme_font_config(theme()), d)
		for _, t in terms do t.cols = 0 // new cell size: resize at the next layout
	}

	w, h := sapp.widthf(), sapp.heightf()
	files_edit_check() // a Files name field that lost the keyboard ends its edit
	term_links_frame() // the link under the pointer, before the layout shows its tip (term_links.odin)
	cmds := ui_layout(w, h)
	bar_layout_done()
	if at != nil {
		if x, y, tw, th, ok := drawer_term_rect(); ok do term_set_rect(at, x, y, tw, th)
	}
	harness_run_keep_sheet() // a running install keeps the setup sheet (harness_install.odin)
	harness_term_layout() // the setup sheet's install terminal (ui_harness.odin)
	if x, y, tw, th, ok := ui_terminal_rect(); ok {
		app.pane = {x, y, tw, th}
		cs := cur()
		ui_pane_rects(cs) // each pane's content rect (panes.odin)
		if cs != nil && len(cs.panes) == 0 do if p := session_focused_pane(cs); p != nil do p.rect = app.pane // the implicit pane: the centre's
		// every terminal tab to its pane's rect, hidden ones too, so a tab switch never reflows
		if cs != nil do for tab in cs.tabs do if t := term_of(tab.id); t != nil {
			r := term_target_rect(tab.id) // never another tab's bars (panes.odin)
			if r.z > 0 do term_set_rect(t, r.x, r.y, r.z, r.w)
		}
	}
	if app.pane.z > 0 do persist_after_layout(skip = app.pending_start)
	browser_tick() // browser tabs follow the pane; new textures (browser.odin)
	annot_tick() // their annotation overlays and markers (browser_annotate.odin)
	browser_polish_tick() // their zoom, bars and fields (browser_polish.odin)
	if app.pending_start && app.pane.z > 0 {
		app.pending_start = false
		cmd := launch_start(app_args.claude, app.launch_project)
		if _, is := cmd.(New_Claude_Session); is do run_command(cmd, {kind = .UI}) // the user's: in front, toast if Claude Code is missing
		else if cmd != nil do run_command(cmd)
		t = active_term()
	}

	editors_frame_begin() // an editor takes hits only where this frame draws it (editor_view.odin)
	annot_frame_begin() // and comment badges where this frame draws them (browser_annotate.odin)
	draw_begin(w, h)
	// chrome, the current tab, the sliding drawer, then a tab drag's drop indicator and ghost, the palette, menus, popover, sheet, tooltip
	overlay := cmds.length
	for name in ([]string{"tab_drop", "tab_ghost", "palette_scrim", "wt_menu_shadow", "wt_menu", "menu_shadow", "menu", "settings_shadow", "settings_pop", "bell_shadow", "bell_pop", "sheet_scrim", "setup_scrim", "jobsheet_scrim", "linktip", "toast", "tooltip"}) do overlay = min(overlay, ui_overlay_start(cmds, name))
	drawer_at := min(ui_overlay_start(cmds, "drawer"), overlay)
	ui_draw(cmds, 0, drawer_at)
	typing := state.focus_widget == "" // no text field has the keyboard
	// the tab each pane shows, in its pane (pages and apps too); marked text in the focused one's (panes.odin)
	if cs := cur(); cs != nil && len(cs.panes) > 1 {
		for &p in cs.panes do pane_draw(&p, t, typing)
	} else if p := focused_pane(); p != nil {
		pane_draw(p, t, typing)
	} // else the layout's empty state shows
	ui_draw(cmds, drawer_at, overlay)
	if at != nil && agent_running() {
		if _, _, tw, th, ok := drawer_term_rect(); ok && tw > 0 && th > 0 {
			term_draw(at)
			if state.focus_widget == "agent_input" do term_draw_marked(at, ime.marked, ime.caret)
		}
	}
	ui_draw(cmds, overlay, cmds.length) // the palette, above the terminals
	if setup_open() do harness_term_draw() // the setup sheet's install terminal, on the sheet
	ui_draw_field_cursor(cmds)
	draw_end()
	update_window_title()
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
	for x in terms_on_screen() do x.changed = false // every pane's terminal was drawn
	if at != nil do at.changed = false
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
	if tab := active_tab(); tab != nil do id = tab.id
	if id == app.drag_tab do return
	app.drag_tab = id
	for tab_id, x in terms do if !tab_on_screen(tab_id) do term_cancel_drag(x)
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
	context = app_context
	defer free_all(context.temp_allocator)
	if autotest_active && !autotest.injecting {
		#partial switch e.type {
		case .KEY_DOWN, .KEY_UP, .CHAR, .MOUSE_DOWN, .MOUSE_UP, .MOUSE_MOVE, .MOUSE_SCROLL, .CLIPBOARD_PASTED, .MOUSE_ENTER, .MOUSE_LEAVE, .FILES_DROPPED:
			return
		}
	}
	event(e)
}

event :: proc(e: ^sapp.Event) {
	defer inbox_drain()
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
	// ⌘K opens the palette from anywhere, and closes it
	if e.type == .KEY_DOWN && e.key_code == .K && only_cmd {
		ime_cancel()
		if !palette_is_open() do palette_reset()
		ui_do(Set_Focus{palette_is_open() ? "" : "palette"})
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
		if was_palette do ui_do(Set_Focus{""})
		if state.home_open && state.focus_widget != "agent_input" && !was_palette && home_tab() != nil && home_tab().status == .Running do ui_do(Set_Focus{"agent_input"})
		else do ui_do(Set_Home{open = !state.home_open})
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
				ui_do(Set_Left_Tab{tab = .Sessions})
				ui_do(Set_Focus{""})
			} else do action_run("settings")
		} else do ui_do(Set_Focus{state.focus_widget == "shortcuts" ? "" : "shortcuts"})
		app.key_taken = true
		return
	}
	// ⌘⇧F: the left column's filter, from anywhere
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
	// the panes' keys (ui_panes.odin): ⌘D ⇧⌘D split, ⌃⌘arrows focus, ⇧⌃⌘arrows move the tab,
	// ⇧⌘W unsplit; from anywhere but a text field
	if e.type == .KEY_DOWN && state.focus_widget == "" && pane_key(e) {
		ime_cancel()
		if menu.open do menu_close()
		app.key_taken = true
		return
	}
	// ⌘⇧E: the Files tab with the keyboard, from anywhere; again: back to Sessions
	if e.type == .KEY_DOWN && e.key_code == .E && e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT) == sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT {
		ime_cancel()
		if menu.open do menu_close()
		if files_shown() && state.focus_widget == "files" {
			ui_do(Set_Left_Tab{tab = .Sessions})
			ui_do(Set_Focus{""})
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
	if editor_bar_focused() && editor_bar_event(focused_pane(), e) do return // its field has the keyboard
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
	t := active_term()
	mt := pane_term(fp) // the pointer's: the pane under it (or holding its press)
	tab := active_tab()
	cs := cur()
	kt := key_term()
	ktab := key_tab()
	#partial switch e.type {
	case .KEY_DOWN:
		if e.modifiers & sapp.MODIFIER_SUPER != 0 {
			#partial switch e.key_code {
			case .C: if ktab != nil do ui_do(Copy_Selection{ktab.id})
			case .Q: ui_do(Quit{})
			// ⌘N: a chat (Chats; the harness picker, harness.odin); ⇧⌘N: a session in the selected project. ⌥⌘T: a Claude tab
			case .N: if e.modifiers & sapp.MODIFIER_ALT == 0 do action_run("new_chat")
			case .T:
				if e.modifiers & sapp.MODIFIER_ALT != 0 do action_run("new_claude_tab")
				else if cs != nil do ui_do(New_Shell_Tab{session = cs.id})
			case .L: // a browser tab: its URL field (browser_nav.odin); else the menu bar's (Go to line)
				if tab_browser() != nil do browser_url_focus()
				else if id := menubar_key_action(e.key_code, e.modifiers); id != "" do action_run(id)
			case .W:
				if state.focus_widget == "agent_input" do ui_do(Set_Home{open = false}) // the drawer, never the tab under it
				else if tab != nil do close_tab_click(tab.id) // like its ×
			case .B:
				if e.modifiers & sapp.MODIFIER_ALT != 0 do ui_do(Set_Layout{right_open = !state.layout.right_open})
				else do ui_do(Set_Layout{left_open = !state.layout.left_open})
			case ._1 ..= ._9:
				if cmd, ok := tab_nth(int(e.key_code) - int(sapp.Keycode._1)); ok do ui_do(cmd) // in the focused pane (actions.odin)
			case .BACKSPACE, .LEFT, .RIGHT: // ⌘⌫ ⌘← ⌘→ alone: line editing (term.odin, mac_key_text)
				if kt != nil && mac_key_text(e.key_code, e.modifiers, false) != "" {
					claude_note_typed(ktab)
					term_key_down(kt, e)
				}
			case: // shortcuts only the menu bar has (⌘+, ⇧⌘], ⌥⌘↓…; menubar.odin)
				if id := menubar_key_action(e.key_code, e.modifiers); id != "" && (id != "markdown_preview" || md_takes_keys()) do action_run(id)
			}
			return // Cmd+V arrives as CLIPBOARD_PASTED
		}
		// a Claude tab's prompt holds text now: Deckhand holds what it would send (claude.odin);
		// Enter submits it (its hook says so) and Esc does not add text
		if kt != nil && e.key_code != .ENTER && e.key_code != .KP_ENTER && e.key_code != .ESCAPE do claude_note_typed(ktab)
		if kt != nil do term_key_down(kt, e)
	case .KEY_UP:
		if kt != nil && e.modifiers & sapp.MODIFIER_SUPER == 0 do term_key_up(kt, e)
	case .CHAR:
		if kt != nil && e.modifiers & sapp.MODIFIER_SUPER == 0 do term_char(kt, e)
	case .CLIPBOARD_PASTED:
		claude_note_typed(ktab)
		if ktab != nil do ui_do(Send_Text{ktab.id, clipboard_text()})
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
			if state.home_open && !state.layout.drawer_pinned do ui_do(Set_Home{open = false})
			else if state.focus_widget == "agent_input" do ui_do(Set_Focus{""})
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
		case Hit_Session:   ui_do(Open_Session_Cmd{state.selected_project, string(hit)})
		case Hit_New:       new_session_ui(state.selected_project, at = [2]f32{e.mouse_x, e.mouse_y}) // the harness picker (harness.odin)
		case Hit_Tab:
			ui_do(Focus_Tab{u64(hit)})
			tab_drag_arm(u64(hit), e.mouse_x, e.mouse_y) // moved a few px, it drags (panes_drag.odin)
			// a double-click keeps a preview tab
			if _, t, _ := find_tab(u64(hit)); t != nil && app.clicks == 2 {
				if et, is := t.kind.(Editor_Tab); is && et.preview do ui_do(Keep_Tab{tab_id = t.id})
			}
		case Hit_Close_Tab: close_tab_click(u64(hit))
		case Hit_Confirm:   if bar_click_ok(string(hit)) do confirm_pending(string(hit))
		case Hit_Cancel:    if bar_click_ok(string(hit)) do ui_do(Cancel_Confirmation{string(hit)})
		case Hit_Panel_Head: ui_do(Set_Panel_Collapsed{panel = string(hit), collapsed = !panel_collapsed(string(hit))})
		case Hit_Palette_Row: // only while the palette has focus (widget_event)
		case Hit_Home:      ui_do(Set_Home{open = !state.home_open})
		case Hit_Close_Session: ui_do(Close_Session{session = u64(hit)})
		case Hit_Chat, Hit_Open_Row, Hit_Pin_Project, Hit_Pin_Session, Hit_New_In, Hit_Add_Project, Hit_Sort, Hit_Fold, Hit_Filter, Hit_Filter_Clear, Hit_Quick, Hit_Waiting_Filtered, Hit_More_Project, Hit_More_Session, Hit_More_Open, Hit_Show_More, Hit_Group, Hit_Kids, Hit_Info_Session, Hit_New_Job_In:
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
		case Hit_Pane_Divider: // pane_divider_press took it
		case Hit_Jobs:      jobs_click(hit)
		case Hit_Button:    button_click(Button(hit))
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
		if notify_wants_seen(state.current_session) do inbox_submit(Notifications_Mark_Read{session = state.current_session}, {kind = .Internal})
		for id in status_wants_seen() do inbox_submit(Set_Unread{tab_id = id, unread = false}, {kind = .Internal}) // agent_status.odin
		if kt != nil do term_focus(kt, true)
	case .UNFOCUSED:
		app.window_active = false
		for _, x in terms {
			term_cancel_drag(x) // its release may go to another app
			term_link_clear(x) // and ⌘'s
		}
		if kt != nil do term_focus(kt, false)
	case .QUIT_REQUESTED:
		// window close / Cmd+Q from the menu: ask first if anything runs
		if !app_quitting {
			sapp.cancel_quit()
			ui_do(Quit{})
			return
		}
		// the window goes first: the handover can wait seconds (an upgrade in flight, the ack, the
		// snapshots), and nothing is drawn meanwhile
		platform_hide_windows()
		if autotest_active do fmt.println("[autotest] quit: windows hidden")
		// keep_sessions: the holder keeps the held tabs (snapshots and handover.json first);
		// otherwise they are released as direct ones are hung up
		if app_stop_sessions do holder_shutdown()
		else do holder_handover()
		relaunch_helper_send("") // an update's helper without a secret (none was handed over): it only relaunches
		persist_quit() // while the shells still run (their cwd is saved; held ids with a handover)
		close_all()
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
pane_draw :: proc(p: ^Pane, t: ^Term, typing: bool) {
	tab := pane_shown(p)
	if tab == nil || (term_of(tab.id) == nil && editor_of(tab.id) == nil && browser_of(tab.id) == nil && app_of(tab.id) == nil) do return
	r := pane_draw_rect(p)
	if r.z <= 0 || r.w <= 0 do return
	tab_view(tab.kind).draw(tab.id, r.x, r.y, r.z, r.w)
	if pt := term_of(tab.id); pt != nil && pt == t && typing do term_draw_marked(pt, ime.marked, ime.caret)
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
	for p in state.pending_confirmations {
		if p.token != token do continue
		cmd := p.command
		#partial switch c in p.command {
		case Close_Tab: cmd = Close_Tab{tab_id = c.tab_id, confirm = token, comments = c.comments}
		case Close_Session: cmd = Close_Session{session = c.session, confirm = token, ask = c.ask, comments = c.comments}
		case Quit:      cmd = Quit{confirm = token, stop_sessions = c.stop_sessions}
		case Update_Install: cmd = Update_Install{confirm = token}
		case Pi_Reload: cmd = Pi_Reload{tab_id = c.tab_id, confirm = token}
		case Pi_Reload_All: cmd = Pi_Reload_All{only_changed = c.only_changed, confirm = token}
		case Pi_Restart_Updated: cmd = Pi_Restart_Updated{confirm = token}
		case Claude_Restart_Changed: cmd = Claude_Restart_Changed{update = c.update, all = c.all, confirm = token}
		case Reload_File: cmd = Reload_File{tab_id = c.tab_id, confirm = token}
		case Delete_Path: cmd = Delete_Path{path = c.path, confirm = token}
		case Create_File: cmd = Create_File{path = c.path, confirm = token}
		case Create_Dir:  cmd = Create_Dir{path = c.path, confirm = token}
		case Rename_Path: cmd = Rename_Path{from = c.from, to = c.to, confirm = token}
		case Worktree_Cleanup: cmd = Worktree_Cleanup{path = c.path, confirm = token}
		case Job_Delete:  cmd = Job_Delete{job = c.job, confirm = token}
		case Changes_Discard: cmd = Changes_Discard{tab_id = c.tab_id, path = c.path, status = c.status, second = c.second, confirm = token}
		case Markdown_Follow: cmd = Markdown_Follow{tab_id = c.tab_id, url = c.url, confirm = token}
		case Set_Claude_Default_Flags: cmd = Set_Claude_Default_Flags{skip_permissions = c.skip_permissions, confirm = token}
		}
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
	before := strings.clone(tf_text(f), context.temp_allocator)
	defer {
		// a changed query starts over at the best match
		if in_palette && tf_text(f) != before do palette_edited()
		// the filter is State: every edit is a set_filter (agents see it too)
		if in_filter && state.focus_widget == "sidebar_filter" && tf_text(f) != before do ui_do(Set_Filter{text = tf_text(f)})
		if in_files_filter && state.focus_widget == "files_filter" && tf_text(f) != before do ui_do(Set_Files_Filter{text = tf_text(f)})
		platform_ime_caret_moved()
	}
	#partial switch e.type {
	case .KEY_DOWN:
		app.redraw = true
		if cmd {
			#partial switch e.key_code {
			case .A: tf_select_all(f)
			case .C: if s := tf_selected_text(f); s != "" do platform.set_clipboard(s)
			case .X:
				if s := tf_selected_text(f); s != "" {
					platform.set_clipboard(s)
					tf_backspace(f)
				}
			case .LEFT, .UP:     tf_home(f, shift)
			case .RIGHT, .DOWN:  tf_end(f, shift)
			case .BACKSPACE:     tf_delete_to_start(f)
			case ._1 ..= ._9:    if in_palette do palette_run_index(palette.first + int(e.key_code) - int(sapp.Keycode._1))
			case .Q:             ui_do(Quit{})
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
				ui_do(Claude_Rename{claude_session_id = rename_session, title = tf_text(f)}) // a Claude row (claude.odin)
				ui_do(Set_Focus{""})
			} else {
				ui_do(Rename_Project{state.selected_project, tf_text(f)})
				ui_do(Set_Focus{""})
			}
		case .ESCAPE:
			if in_filter do ui_do(Set_Filter{text = ""}) // Esc clears the filter
			ui_do(Set_Focus{""})
		case .BACKSPACE: if alt do tf_delete_word_left(f); else do tf_backspace(f)
		case .DELETE:    tf_delete(f)
		case .LEFT:      if alt do tf_word_left(f, shift); else do tf_move(f, -1, shift)
		case .RIGHT:     if alt do tf_word_right(f, shift); else do tf_move(f, 1, shift)
		case .HOME:      tf_home(f, shift)
		case .END:       tf_end(f, shift)
		case .UP:
			if in_palette do palette_move(-1)
			else do tf_home(f, shift)
		case .DOWN:
			if in_palette do palette_move(1)
			else do tf_end(f, shift)
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
				ui_do(Set_Focus{""}) // a click outside closes it (and does nothing else)
				return true
			}
			if !field_inside(box_id, e.mouse_x, e.mouse_y) do return true
		} else if !field_inside(box_id, e.mouse_x, e.mouse_y) {
			// a click outside the field ends editing (and is handled normally)
			ime_cancel()
			ui_do(Set_Focus{""})
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
	if f, _, _ := focused_field(); f != nil {
		tf_insert(f, text)
		if state.focus_widget == "palette" do palette_edited()
	} else if t := key_term(); t != nil {
		claude_note_typed(key_tab())
		term_text_input(t, text)
	} else if ed := active_editor(); ed != nil {
		editor_ime_commit(ed, text)
	}
	app.redraw = true
}

ime_set_marked :: proc(text: string, caret: int) {
	if !autotest_allows_input() do return
	if text == ime.marked do return
	delete(ime.marked)
	ime.marked = strings.clone(text)
	ime.caret = caret
	app.redraw = true
	if t := key_term(); t != nil do t.changed = true
}

ime_cancel :: proc() {
	if ime.marked == "" do return
	platform_ime_cancel()
	ime_set_marked("", 0)
}

// Option starts dead keys (é, ü) in text fields; in a terminal it is Alt.
ime_option_composes :: proc() -> bool {return state.focus_widget != "" || active_editor() != nil}

// The candidate window's anchor: the field caret, else the terminal cursor.
ime_anchor :: proc() -> [4]f32 {
	if state.focus_widget == "" {
		if t := key_term(); t != nil do return {t.cursor_px.x, t.cursor_px.y, font.cell_w, font.cell_h}
	}
	return ime.caret_rect // a field's caret, or the editor's (editor_draw)
}

// Window title (hidden in the title bar; Mission Control, the Window menu
// and ⌘` show it): the current session's title.
update_window_title :: proc() {
	title := "Deckhand"
	if cs := cur(); cs != nil {
		_, place := session_place(cs)
		title = fmt.tprintf("%s · %s — Deckhand", place, open_session_title(cs))
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
	context = app_context
	login_env_kill_probe() // a refresh's shell still running (login_env.odin)
	harness_no_sudo_sweep(at_quit = true) // a run's no-sudo folder (harness_install.odin)
	persist_quit()
	titles_save()
	socket_stop()
	jobs_shutdown()
	close_all()
	holder_client_stop() // the session holder's connection (holder_client.odin)
	browser_shutdown() // CEF before sokol (browser.odin)
	app_shutdown() // app tabs' processes (app_tab.odin)
	comments_shutdown() // this run's crops (comments.odin)
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

when TEST_HOOKS {
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
launch_project :: proc(r: Result) -> u64 {
	return r.ok ? r.created_id : 0
}

// What `deckhand DIR` starts in project pid once the pane has a size: a pi chat (a Claude session when
// Claude Code is the only harness installed), or with --claude a
// Claude session (the user's own launch: it comes to the front; without Claude Code a toast says
// how to install it).
launch_start :: proc(claude: bool, pid: u64) -> Command {
	if pid == 0 || find_project(pid) == nil do return nil // never the project that happened to be selected
	if claude do return New_Claude_Session{project_id = pid}
	if !pi_installed() && claude_installed() do return New_Claude_Session{project_id = pid} // Claude Code alone (harness.odin)
	return New_Chat{pid}
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
	persist.launch = time.tick_now()
	if len(os.args) > 1 && os.args[1] == "--ctl" do os.exit(ctl_main(os.args[2:]))
	ok: bool
	app_args, ok = app_args_parse(os.args[1:])
	if !ok {
		fmt.eprintln(APP_USAGE)
		os.exit(2)
	}
	app_context = context
	// from the Dock or Finder: the login shell's environment, before any thread (login_env.odin)
	login_env_startup()
	when TEST_HOOKS {
		// test mode is quiet unless DECKHAND_QUIET=0: the window never shows or takes focus
		if hook_env(.Script) != "" && hook_env(.Quiet) != "0" do platform_quiet()
		// test mode: the same backing scale on every Mac (DECKHAND_SCALE, default 1), quiet or not
		if hook_env(.Script) != "" {
			scale, sok := test_scale_parse(hook_env(.Scale))
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
