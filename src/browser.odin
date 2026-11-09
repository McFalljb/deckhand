package main

// Browser tabs, step 1 (the go/no-go spike in docs/BROWSER.md §6): a
// windowless CEF browser drawn as the tab's texture, with mouse, wheel and
// keys forwarded. CEF starts on the first browser tab (lazily) and shuts
// down at quit. The shim is src/native/cef_macos.m, its bindings
// browser_cef.odin.
//
// Frames: each tab has a frame ring like an app tab's (frames.odin), over a
// local channel: CEF paints into a slot Deckhand does not sample, the frame
// loop takes the newest one before drawing (browser_frames_tick), and a slot
// a frame stopped showing goes back only after that frame's GPU work is done
// (dh_frames_committed). Unlike an app's, the ring follows the size CEF
// paints at, with headroom: its surfaces are rounded up to RING_GRID px and
// each frame says how much of its slot it fills (drawn alone). A paint too
// big for the ring asks for a larger one (on_cef_ring): made at once, or,
// if one was made in the last RING_SETTLE (a drag), by the frame loop once
// that time passed, which then has CEF paint again. A ring a grid step too
// big is replaced once the size stayed put for RING_SETTLE. The old ring
// goes once nothing shows it.
//
// Step 2 (browser_nav.odin): browser_open and the other browser_* commands,
// the toolbar, State per tab (url, title, loading, can_back, can_forward),
// popups (on_cef_popup) and saving the tabs. What CEF reports goes into State
// through the inbox (browser_report). Test mode also opens a tab with
// `web_open`, a run with DECKHAND_DEBUG_BROWSER=URL at launch.
//
// A browser tab belongs to one session for its whole life (state.odin):
// browser_open takes the session explicitly (the core: tabhost_route.odin): a user's action passes the
// session on screen, a command or an agent its own session (the caller's),
// never "whatever is focused" at the time it runs. Popups, target=_blank and
// window.open (OnBeforePopup, on_cef_popup) open a new tab in the opener's
// session, never the one on screen; without a user gesture they are refused
// (blocked_popup in State; the bar to open it anyway is step 3). No path moves a tab to another session.
// What the page makes (pending comments, comments.odin) goes to its session's
// pi, whichever session is on screen.

import "core:c"
import "core:encoding/json"
import "core"
import jg "jsonguard"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import sapp "../vendor/sokol-odin/sokol/app"
import sg "../vendor/sokol-odin/sokol/gfx"
import sgl "../vendor/sokol-odin/sokol/gl"
import clay "../build/clay-odin"

// Runtime per browser tab (outside State), keyed by tab id.
Browser :: struct {
	tab_id:      u64,
	cef:         c.int, // the shim's browser id; 0 = not created yet (or failed)
	url:         string,
	ring:        Frame_Ring, // the slots CEF paints into (frames.odin)
	chan:        bool, // its local channel is open
	content_w:   int, // the shown frame's size in its slot (px)
	content_h:   int,
	paint_w:     int, // the size CEF last painted at, or asked a ring for (px)
	paint_h:     int,
	paint_since: time.Tick, // when that size changed
	last_ring:   time.Tick, // when the last ring was made
	title:       string,
	loading:     bool,
	painted:     u64, // frames received
	accelerated: bool, // the last frame came through the shared texture
	hidden:      bool,
	focused:     bool,
	message:     string, // shown instead of the page ("Browser not built in")
	opened_at:   time.Tick, // web_open: the tab was asked for
	first_paint: time.Duration, // from opened_at, CEF start included
	buttons:     c.int, // mouse buttons held (CEF modifier flags)
	opens:       int, // browsers created for this tab (tests: a page is not reopened behind your back)
	closed_by_page: bool, // window.close(): not reopened until Reload
	lazy:        bool, // restored or unloaded: its page opens when it is shown (browser_page_plan)
	waiting:     bool, // no CEF slot was free: opens when one frees (message says so)
	shown_at:    time.Tick, // when it was last on screen (or opened): which page goes first
	view_w:      c.int, // the view's size last given to CEF (logical px) and scale
	view_h:      c.int,
	view_scale:  f32,
	resized_at:  time.Tick, // when that changed (an agent's screenshot waits for it to settle)
	held:        bit_set[0 ..< 128], // macOS key codes pressed in the page and not released yet
	held_ch:     [128]u16, // their characters (a key-up without one is dropped)
	last_x:      c.int, // the pointer's last page position (logical px): releases and leaves go there
	last_y:      c.int,
	drawn_tex:   rawptr, // the texture the last frame drawn sampled (its GPU work may still be running)
	overwrites:  int, // paints written into drawn_tex (tests: the race of BROWSER.md §6 step 2; must stay 0)
	rings_made:  int, // rings created for this tab (tests: churn on a resize)
	rings_mark:  int, // rings_made at web_mark
	surf_peak:   int, // the most ring surfaces alive at once since web_mark
	ring_bytes:  u64, // bytes of every ring created (tests: churn)
	bytes_mark:  u64, // ring_bytes at web_mark
}

browsers: map[u64]^Browser
browser_sampler: sg.Sampler
browser_images: int // sokol images wrapping ring slots, alive (tests: every one is destroyed)
browser_frames: bool // a local channel was opened: commit posts releases
RING_GRID :: 256 // a browser ring's surfaces are rounded up to this (px): a drag mostly fits
cef_start_ms: f64 // how long dh_cef_start took (lazy start, once)
cef_state: enum {
	Off,
	Running,
	Failed,
}

browser_host := Tab_View {
	display = .Texture,
	draw = proc(tab_id: u64, x, y, w, h: f32) {browser_draw(tab_id, x, y, w, h)},
	texture = proc(tab_id: u64) -> u32 {
		b := browsers[tab_id]
		if b == nil do return 0
		g := ring_gen(&b.ring, b.ring.shown_gen)
		return g != nil ? g.image[b.ring.shown_slot] : 0
	},
}

browser_of :: proc(tab_id: u64) -> ^Browser {return browsers[tab_id]}

// The browser of the tab on screen, or nil.
tab_browser :: proc() -> ^Browser {
	if tab := core.active_tab(); tab != nil do return browsers[tab.id]
	return nil
}


// A browser tab's runtime (a new tab, a restored one once its session is
// focused); CEF opens the page in browser_tick.
browser_attach :: proc(tab_id: u64, url: string) -> ^Browser {
	b := new(Browser)
	b.tab_id = tab_id
	b.url = strings.clone(url)
	b.opened_at = time.tick_now()
	b.shown_at = b.opened_at
	if !CEF_BUILT_IN do b.message = "Browser not built in (a build without CEF)" // no DECKHAND_ name: scripts/check-release-build.sh
	browsers[tab_id] = b
	app.redraw = true
	return b
}

// The page goes to url (browser_navigate): now, or when CEF opens it.
browser_go :: proc(tab_id: u64, url: string) {
	b := browsers[tab_id]
	if b == nil do return
	delete(b.url)
	b.url = strings.clone(url)
	if b.cef != 0 do dh_cef_navigate(b.cef, strings.clone_to_cstring(url, context.temp_allocator))
	else if b.closed_by_page do browser_reopen(b, url)
}

// A page that closed itself (or failed to open) opens again at url (Reload,
// browser_navigate). False: it is not closed.
browser_reopen :: proc(b: ^Browser, url: string) -> bool {
	if b.cef != 0 || (!b.closed_by_page && b.message == "") || b.waiting do return false
	if !CEF_BUILT_IN do return false
	if url != "" && url != b.url {
		delete(b.url)
		b.url = strings.clone(url)
	}
	b.closed_by_page = false
	b.message = "" // browser_tick opens it
	app.redraw = true
	return true
}

@(private = "file")
cef_start :: proc() -> bool {
	switch cef_state {
	case .Running: return true
	case .Failed: return false
	case .Off:
	}
	cef_state = .Failed
	if !CEF_BUILT_IN do return false
	// macOS's Library lookups ignore $HOME: a scene without CFFIXED_USER_HOME
	// on its fake home would let Chromium write the user's ~/Library (RLZ)
	if core.autotest_active && os.get_env("CFFIXED_USER_HOME", context.temp_allocator) == "" {
		fmt.println("[browser] test mode: CEF needs CFFIXED_USER_HOME (the scene's fake home)")
		return false
	}
	root := browser_root(context.temp_allocator)
	profile, _ := filepath.join({root, "browser", "profile"}, context.temp_allocator)
	os.make_directory_all(profile)
	// the profile's cookies are protected by file permissions alone (mock
	// Keychain key, so no Keychain prompt): only the user may enter it
	browser_dir, _ := filepath.join({root, "browser"}, context.temp_allocator)
	for d in ([]string{browser_dir, profile}) do posix.chmod(strings.clone_to_cstring(d, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	rlz_off(profile)
	log_file, _ := filepath.join({root, "browser", "cef.log"}, context.temp_allocator)
	shared_env, set := os.lookup_env("DECKHAND_CEF_SHARED_TEXTURE", context.temp_allocator)
	if !set do shared_env = os.get_env("PI_DESK_CEF_SHARED_TEXTURE", context.temp_allocator) // its old name
	shared: c.int = shared_env == "0" ? 0 : 1
	cbs := Cef_Callbacks {
		painted = on_cef_painted,
		ring = on_cef_ring,
		title = on_cef_title,
		loading = on_cef_loading,
		closed = on_cef_closed,
		log = proc "c" (s: cstring) {context = core.app_context; fmt.println("[browser]", s)},
		address = on_cef_address,
		nav = on_cef_nav,
		popup = on_cef_popup,
	}
	// test mode never touches the network (SPIKE: the real policy for Chromium's
	// Google services is open, see the report)
	no_network: c.int = core.autotest_active || core.hook_env(.Cef_Offline) == "1" ? 1 : 0
	t0 := time.tick_now()
	ok := dh_cef_start(sg.mtl_device(), strings.clone_to_cstring(profile, context.temp_allocator), strings.clone_to_cstring(log_file, context.temp_allocator), shared, no_network, &cbs) == 1
	cef_start_ms = time.duration_milliseconds(time.tick_since(t0))
	if ok do cef_state = .Running
	if ok && core.autotest_active {
		// deckhand-test://web/NAME: the fixtures in tests/web (no network)
		cwd, _ := os.get_working_directory(context.temp_allocator)
		web, _ := filepath.join({cwd, "tests", "web"}, context.temp_allocator)
		if dh_cef_test_scheme(strings.clone_to_cstring(web, context.temp_allocator)) != 1 do fmt.println("[browser] test mode: deckhand-test:// not registered")
	}
	return ok
}

// Chromium's RLZ (Google's brand and promotion tracker) pings
// clients1.google.com from its store under Library/Application Support/Google/RLZ
// (Deckhand's own: cef_macos.m gives Chromium its own Library). It has no
// switch: its start is delayed by the profile preference rlz_ping_delay (90 s),
// read once at startup. Set to ten years before CEF starts, it never pings
// (real use also maps clients1.google.com to nothing). docs/BROWSER.md §2.3.
RLZ_OFF_DELAY :: 10 * 365 * 24 * 3600

@(private = "file")
rlz_off :: proc(profile: string) {
	dir, _ := filepath.join({profile, "Default"}, context.temp_allocator)
	path, _ := filepath.join({dir, "Preferences"}, context.temp_allocator)
	os.make_directory_all(dir)
	root: json.Object
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		v, perr := jg.parse(data, .JSON, true, context.temp_allocator)
		if obj, ok := v.(json.Object); perr == nil && ok do root = obj
		else {
			fmt.println("[browser] the profile's Preferences do not parse: RLZ delay not set")
			return // never overwrite what Chromium could still read
		}
	} else do root = make(json.Object, context.temp_allocator)
	if n, ok := root["rlz_ping_delay"].(json.Integer); ok && n == RLZ_OFF_DELAY do return
	root["rlz_ping_delay"] = json.Integer(RLZ_OFF_DELAY)
	out, merr := json.marshal(json.Value(root), {}, context.temp_allocator)
	if merr != nil do return
	tmp := fmt.tprintf("%s.deckhand-%d", path, os.get_pid())
	f, err := os.open(tmp, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if err != nil do return
	_, werr := os.write(f, out)
	os.close(f)
	if werr == nil do werr = os.rename(tmp, path)
	if werr != nil do os.remove(tmp)
}

@(private = "file")
by_cef :: proc(id: c.int) -> ^Browser {
	for _, b in browsers do if b.cef == id do return b
	return nil
}

@(private = "file")
on_cef_painted :: proc "c" (id: c.int, w, h: c.int, accelerated: c.int, written: rawptr) {
	context = core.app_context
	b := by_cef(id)
	if b == nil do return
	if written != nil && written == b.drawn_tex do b.overwrites += 1
	if b.painted == 0 do b.first_paint = time.tick_since(b.opened_at)
	b.painted += 1
	browser_paint_size(b, int(w), int(h))
	b.accelerated = accelerated != 0
	if !b.hidden do app.redraw = true
}

// No ring fits a w x h px paint (the first paint, a larger pane or scale):
// one now, unless one was made in the last RING_SETTLE (a drag: the frame
// loop makes it once that passed, browser_ring_sizing). 1 = made.
@(private = "file")
on_cef_ring :: proc "c" (tab_id: u64, w, h: c.int) -> c.int {
	context = core.app_context
	b := browsers[tab_id]
	if b == nil || !b.chan do return 0
	browser_paint_size(b, int(w), int(h))
	if b.ring.cur_gen != 0 && time.tick_diff(b.last_ring, time.tick_now()) < RING_SETTLE do return 0
	return browser_ring_make(b, int(w), int(h)) ? 1 : 0
}

ring_grid_up :: proc(px: int) -> int {return (px + RING_GRID - 1) / RING_GRID * RING_GRID}

// The size CEF paints at now (px).
@(private = "file")
browser_paint_size :: proc(b: ^Browser, w, h: int) {
	if w == b.paint_w && h == b.paint_h do return
	b.paint_w, b.paint_h, b.paint_since = w, h, time.tick_now()
}

// A ring for w x h px paints (rounded up to RING_GRID), which the producer
// uses from now on, so the old one is done (as an app's RING_DONE) and goes
// once not on screen.
@(private = "file")
browser_ring_make :: proc(b: ^Browser, w, h: int) -> bool {
	browser_free_rings(b) // room for it: rings nothing shows any more
	rw, rh := ring_grid_up(w), ring_grid_up(h)
	gen := dh_frames_ring_new(b.tab_id, c.int(rw), c.int(rh), app.dpi)
	if gen == 0 do return false
	g := Ring_Gen{gen = gen, w = rw, h = rh, scale = app.dpi}
	for s in 0 ..< FRAME_SLOTS {
		tex := dh_frames_slot_texture(b.tab_id, gen, c.int(s))
		g.image[s] = sg.make_image({width = c.int(rw), height = c.int(rh), pixel_format = .BGRA8, mtl_texture = tex}).id
		g.view[s] = sg.make_view({texture = {image = {g.image[s]}}}).id
		browser_images += 1
	}
	append(&b.ring.gens, g)
	if b.ring.cur_gen != 0 do b.ring.done_gen = b.ring.cur_gen
	b.ring.cur_gen = gen
	b.last_ring = time.tick_now()
	b.rings_made += 1
	b.ring_bytes += u64(rw) * u64(rh) * 4 * FRAME_SLOTS
	b.surf_peak = max(b.surf_peak, int(dh_frames_surface_count(b.tab_id)))
	return true
}

// Whether the ring should be remade for paints of w x h px: it is too small
// (at most one ring per RING_SETTLE: a drag waits), or a grid step too big
// and the size stayed put for RING_SETTLE. Pure but for the clock passed in.
browser_ring_due :: proc(ring_w, ring_h, w, h: int, paint_since, last_ring, now: time.Tick) -> bool {
	if w <= 0 || h <= 0 do return false
	gw, gh := ring_grid_up(w), ring_grid_up(h)
	if gw == ring_w && gh == ring_h do return false
	if time.tick_diff(last_ring, now) < RING_SETTLE do return false
	fits := w <= ring_w && h <= ring_h
	return !fits || time.tick_diff(paint_since, now) >= RING_SETTLE
}

// Every frame: a ring CEF's paints need and could not have at once (see
// browser_ring_due); CEF then paints the view again into it.
@(private = "file")
browser_ring_sizing :: proc(b: ^Browser, now: time.Tick) {
	if b.cef == 0 || b.ring.cur_gen == 0 do return
	cur := ring_gen(&b.ring, b.ring.cur_gen)
	if cur == nil || !browser_ring_due(cur.w, cur.h, b.paint_w, b.paint_h, b.paint_since, b.last_ring, now) do return
	if browser_ring_make(b, b.paint_w, b.paint_h) do dh_cef_invalidate(b.cef)
}

@(private = "file")
browser_slot_destroy :: proc(g: ^Ring_Gen, s: int) {
	if g.image[s] == 0 do return
	sg.destroy_view({g.view[s]})
	sg.destroy_image({g.image[s]})
	g.image[s], g.view[s] = 0, 0
	browser_images -= 1
}

// Frees the rings that may go (frames.odin's ring_freeable): replaced by a
// newer one and not on screen.
@(private = "file")
browser_free_rings :: proc(b: ^Browser) {
	gens := make([dynamic]u32, context.temp_allocator)
	ring_freeable(&b.ring, false, &gens)
	for gen in gens {
		for g, i in b.ring.gens {
			if g.gen != gen do continue
			for s in 0 ..< FRAME_SLOTS do browser_slot_destroy(&b.ring.gens[i], s)
			dh_frames_ring_free(b.tab_id, gen, -1)
			ordered_remove(&b.ring.gens, i)
			break
		}
	}
}

// Every frame, before `if !app.redraw` (main.odin): the newest frame CEF
// handed over becomes the shown one on every tab on screen (any pane's), and
// the slot it replaces goes back after this frame's GPU work; a hidden tab's
// goes back at once (never its shown slot). True: redraw.
browser_frames_tick :: proc() -> bool {
	if len(browsers) == 0 do return false
	redraw := false
	now := time.tick_now()
	for id, b in browsers {
		if !b.chan do continue
		p: Frames_Poll
		dh_frames_poll(id, &p)
		if p.has_frame != 0 {
			if core.tab_on_screen(id) || browser_agent_wakes(id) { // or painted for an agent's screenshot (browser_agent.odin)
				og, os_, retire := ring_take(&b.ring, p.gen, p.slot, p.seq, p.tick)
				if retire do dh_frames_retire(id, og, u32(os_))
				b.ring.last_frame = now // live frames on screen: the display link stays fast (frames.odin)
				if b.ring.shown_gen == p.gen && b.ring.shown_slot == int(p.slot) do b.content_w, b.content_h = int(p.content_w), int(p.content_h)
				redraw = true
			} else if ring_may_release_now(&b.ring, p.gen, p.slot) do dh_frames_release_now(id, p.gen, p.slot) // never drawn
		}
		browser_ring_sizing(b, now)
		browser_free_rings(b)
		b.surf_peak = max(b.surf_peak, int(dh_frames_surface_count(id)))
	}
	return redraw
}

// A browser tab on screen painted within DISPLAY_FAST_HOLD (the display link's rate: frames.odin).
browser_frames_live :: proc() -> bool {
	now := time.tick_now()
	for id, b in browsers do if display_tab_live(core.tab_on_screen(id), false, ring_framed_recently(&b.ring, now)) do return true
	return false
}

// After sg.commit (main.odin): the retired slots go back once this frame's GPU work is done.
browser_frames_committed :: proc() {
	if browser_frames do dh_frames_committed(sg.mtl_command_queue())
}

@(private = "file")
on_cef_title :: proc "c" (id: c.int, utf8: cstring) {
	context = core.app_context
	b := by_cef(id)
	if b == nil do return
	delete(b.title)
	b.title = strings.clone(string(utf8))
	browser_report({tab_id = b.tab_id, what = {.Title}, title = b.title}) // the tab's title (State)
	app.redraw = true
}

// The main frame's address (a link, a redirect, back/forward).
@(private = "file")
on_cef_address :: proc "c" (id: c.int, utf8: cstring) {
	context = core.app_context
	b := by_cef(id)
	if b == nil do return
	browser_report({tab_id = b.tab_id, what = {.Url}, url = string(utf8)})
}

@(private = "file")
on_cef_nav :: proc "c" (id: c.int, loading, can_back, can_forward: c.int) {
	context = core.app_context
	b := by_cef(id)
	if b == nil do return
	browser_report({tab_id = b.tab_id, what = {.Nav}, loading = loading != 0, can_back = can_back != 0, can_forward = can_forward != 0})
}

// target=_blank, window.open, ⌘-click (docs/BROWSER.md §2.5): a new tab in
// the opener's session (never the one on screen), its browser in the shim's
// slot `slot`; refused without a user gesture (blocked_popup, for the bar of
// step 3) or with no slot left. Returns the new tab's id, 0 = refused.
//
// The tab's record is the core's: the page's popup goes to it as a tab_host.event
// (Browser_Popup_Open, the tab_host caller: a page never acts as the user) and its id comes
// back at once, because the shim needs it now to reserve the slot CEF's browser lands in. CEF
// calls this on the main thread from the pump (a GCD main-queue timer, never inside a frame, an
// event or a command), as run_command would run.
@(private = "file")
on_cef_popup :: proc "c" (opener, slot: c.int, url: cstring, user_gesture, background: c.int) -> u64 {
	context = core.app_context
	ob := by_cef(opener)
	if ob == nil do return 0
	s, _, _ := find_tab(ob.tab_id)
	if s == nil do return 0
	u := string(url)
	if user_gesture == 0 {
		browser_popup_refused(ob.tab_id, u) // counted; the bar and the log at most once a second (browser_polish.odin)
		return 0
	}
	if slot == 0 {
		fmt.printfln("[browser] popup refused: no browser slot left (%s)", u)
		return 0
	}
	// an agent's click opens it behind, in the agent's pane: an agent never changes what the user
	// sees (browser_act.odin)
	agent := browser_act_busy(ob.tab_id)
	r := tab_host_report_now(core.Browser_Popup_Open{opener = ob.tab_id, url = u, background = background != 0 || agent, pane = browser_popup_pane(s, ob.tab_id)})
	id := r.created_id
	if !r.ok || id == 0 {
		fmt.printfln("[browser] popup refused: %s", r.error != "" ? r.error : "no tab")
		return 0
	}
	b := browser_attach(id, u)
	if agent do browser_act_popup(ob.tab_id, id)
	if !browser_chan(b) {
		b.message = "The browser has no frame channel left (too many tabs)"
		return 0
	}
	b.cef = slot // the shim reserved it; the browser arrives in on_after_created (dh_cef_ready)
	b.opens += 1
	return id
}

// The tab's frame channel (once). False: none left.
@(private = "file")
browser_chan :: proc(b: ^Browser) -> bool {
	if b.chan do return true
	b.chan = dh_frames_local_open(b.tab_id, sg.mtl_device()) == 1
	browser_frames ||= b.chan
	if core.autotest_active {
		// count writes into any texture an uncompleted GPU frame samples;
		// DECKHAND_TEST_GPU_LAG_MS: a slow GPU (the completed handler's work waits)
		lag, _ := strconv.parse_int(core.hook_env(.Gpu_Lag_Ms))
		dh_frames_test_track(1, c.int(lag))
	}
	return b.chan
}

@(private = "file")
on_cef_loading :: proc "c" (id: c.int, loading: c.int) {
	context = core.app_context
	if b := by_cef(id); b != nil do b.loading = loading != 0
}

@(private = "file")
on_cef_closed :: proc "c" (id: c.int) {
	context = core.app_context
	b := by_cef(id)
	if b == nil do return // Deckhand closed it (browser_drop) or quit
	// the page closed itself (window.close()): say so; Reload opens it again
	b.cef = 0
	b.closed_by_page = true
	b.message = "The page closed itself"
	b.held, b.buttons, b.focused, b.hidden = {}, 0, false, false
	app.redraw = true
}

// Lets go of what the page holds: the keys and buttons pressed in it get
// their releases (the page lost the keyboard, or the tab went away).
@(private = "file")
release_input :: proc(b: ^Browser) {
	for code in b.held do dh_cef_key(b.cef, CEF_KEY_UP, c.int(code), 0, b.held_ch[code], b.held_ch[code])
	b.held = {}
	for button in c.int(0) ..= 2 {
		flag: c.int = button == 0 ? CEF_FLAG_LEFT_BUTTON : button == 1 ? 1 << 5 : 1 << 6
		if b.buttons & flag == 0 do continue
		b.buttons &~= flag
		dh_cef_mouse_click(b.cef, b.last_x, b.last_y, b.buttons, button, 1, 1)
	}
}

// Every frame, before layout: create browsers that have a pane, follow each
// one's pane size and the scale, hide browsers that are not on screen (in no
// pane), and wrap a new texture when the shim made one. Only the focused
// pane's page has the keyboard.
browser_tick :: proc() {
	browser_url_check() // the URL field belongs to the tab it was opened on (browser_nav.odin)
	if len(browsers) == 0 do return
	now := time.tick_now()
	for _, b in browsers do if core.tab_on_screen(b.tab_id) {
		b.shown_at = now // the page plan's LRU: never an on-screen page's slot
		b.lazy = false // shown: its page opens
	}
	browser_pages()
	for _, b in browsers {
		hidden := !core.tab_on_screen(b.tab_id)
		// a popup's browser is not there until CEF made it (on_after_created)
		if b.cef == 0 || dh_cef_ready(b.cef) == 0 do continue
		focused := browser_wants_keys(b)
		if focused != b.focused {
			if !focused do release_input(b) // before it hides: held keys and buttons are let go
			b.focused = focused
			dh_cef_focus(b.cef, focused ? 1 : 0)
		}
		// a tab an agent's screenshot waits for paints (unseen: it is not drawn)
		paint_hidden := hidden && !browser_agent_wakes(b.tab_id)
		if paint_hidden != b.hidden {
			b.hidden = paint_hidden
			dh_cef_set_hidden(b.cef, paint_hidden ? 1 : 0)
		}
		if r := tab_rect(b.tab_id); !hidden && r.z > 0 {
			vw, vh := c.int(r.z / app.dpi), c.int(r.w / app.dpi)
			if vw != b.view_w || vh != b.view_h || app.dpi != b.view_scale {
				b.view_w, b.view_h, b.view_scale = vw, vh, app.dpi
				b.resized_at = now
			}
			dh_cef_resize(b.cef, vw, vh, app.dpi)
		}
	}
}

// The page has Deckhand's keyboard: its tab is the focused one (panes.odin) and no widget has
// the keyboard.
browser_wants_keys :: proc(b: ^Browser) -> bool {
	return core.tab_focused(b.tab_id) && state.focus_widget == ""
}

BROWSER_WAIT_MESSAGE :: "Too many open pages: this one opens when another closes"

// Which tabs have a page (browser_page_plan, browser_nav.odin): open, unload,
// park or wait, once the pane has a size.
@(private = "file")
browser_pages :: proc() {
	if app.pane.z <= 0 do return
	list := make([dynamic]^Browser, context.temp_allocator)
	pages := make([dynamic]Page_Info, context.temp_allocator)
	for _, b in browsers {
		s, _, _ := find_tab(b.tab_id)
		if s == nil do continue
		live := b.cef != 0
		wants := !live && !b.lazy && (b.message == "" || b.waiting)
		if !live && !wants do continue
		append(&list, b)
		append(&pages, Page_Info{session = s.id, live = live, wants = wants, visible = core.tab_on_screen(b.tab_id), pinned = live && dh_cef_ready(b.cef) == 0, shown = i64(b.shown_at._nsec)})
	}
	if len(pages) == 0 do return
	want_any := false
	for x in pages do want_any ||= x.wants
	if want_any && !cef_start() {
		for b, i in list do if pages[i].wants do b.message = "The browser could not start (see the log)"
		return
	}
	// a slot whose page is closing counts as free: it is, in a moment (no second page goes for it)
	plan := browser_page_plan(pages[:], int(dh_cef_free_slots(1)))
	for i in plan.unload do browser_unload(list[i])
	for i in plan.wait {
		b := list[i]
		if !b.waiting do browser_report({tab_id = b.tab_id}) // State: page "waiting"
		b.waiting, b.message = true, BROWSER_WAIT_MESSAGE
	}
	for i in plan.load {
		b := list[i]
		if !browser_chan(b) {
			b.waiting, b.message = false, "The browser has no frame channel left (too many tabs)"
			continue
		}
		r := tab_rect(b.tab_id) // its pane's size (panes.odin)
		w, h := c.int(r.z / app.dpi), c.int(r.w / app.dpi)
		b.cef = dh_cef_open(strings.clone_to_cstring(b.url, context.temp_allocator), w, h, app.dpi, b.tab_id)
		if b.cef == 0 {
			// no slot yet (one is still closing): wait; else it failed
			if dh_cef_free_slots(0) == 0 do b.waiting, b.message = true, BROWSER_WAIT_MESSAGE
			else do b.waiting, b.message = false, "The browser could not open this page"
			continue
		}
		b.opens += 1
		b.waiting, b.message = false, ""
		browser_report({tab_id = b.tab_id}) // State: page "open"
	}
}

// Its page goes (another tab needs the slot, or its session has too many):
// the tab keeps its URL and opens it again when shown. Its history goes.
browser_unload :: proc(b: ^Browser) {
	if b.cef == 0 do return
	release_input(b)
	// cef cleared first: CEF may say "closed" inside dh_cef_close, and
	// on_cef_closed must then find nothing (Deckhand closed it, not the page)
	id := b.cef
	b.cef = 0
	dh_cef_close(id)
	browser_free_page(b)
	b.lazy = true
	b.focused, b.hidden = false, false
	b.painted, b.content_w, b.content_h, b.paint_w, b.paint_h = 0, 0, 0, 0, 0
	b.drawn_tex = nil
	browser_report({tab_id = b.tab_id, what = {.Nav}}) // loading, back and forward: none now
	fmt.printfln("[browser] tab %d unloaded (its page loads again when shown)", b.tab_id)
}

// The page's frames: its rings, images and frame channel (the tab closes or unloads).
@(private = "file")
browser_free_page :: proc(b: ^Browser) {
	// the ring goes now (sokol and Metal keep what in-flight frames sample)
	for &g in b.ring.gens do for s in 0 ..< FRAME_SLOTS do browser_slot_destroy(&g, s)
	delete(b.ring.gens)
	b.ring = {}
	if b.chan do dh_frames_chan_close(b.tab_id)
	b.chan = false
}

// The page's last frame at the pane's top-left, 1:1 in framebuffer px
// (clipped to the pane while a resize is on its way).
browser_draw :: proc(tab_id: u64, x, y, w, h: f32) {
	b := browsers[tab_id]
	if b == nil || b.cef == 0 || b.ring.shown_gen == 0 do return
	g := ring_gen(&b.ring, b.ring.shown_gen)
	if g == nil || g.image[b.ring.shown_slot] == 0 || b.content_w <= 0 do return
	if browser_sampler.id == 0 do browser_sampler = sg.make_sampler({min_filter = .LINEAR, mag_filter = .LINEAR})
	// the frame fills the slot's top-left content_w x content_h (headroom beyond)
	dw, dh := min(f32(b.content_w), w), min(f32(b.content_h), h)
	u, v := dw / f32(g.w), dh / f32(g.h)
	b.drawn_tex = dh_frames_slot_texture(b.tab_id, g.gen, c.int(b.ring.shown_slot))
	if core.autotest_active do dh_frames_sampled(b.drawn_tex) // in flight until this frame's GPU work completes
	sgl.end()
	sgl.texture({g.view[b.ring.shown_slot]}, browser_sampler)
	sgl.begin_quads()
	sgl.v2f_t2f_c4b(x, y, 0, 0, 255, 255, 255, 255)
	sgl.v2f_t2f_c4b(x + dw, y, u, 0, 255, 255, 255, 255)
	sgl.v2f_t2f_c4b(x + dw, y + dh, u, v, 255, 255, 255, 255)
	sgl.v2f_t2f_c4b(x, y + dh, 0, v, 255, 255, 255, 255)
	sgl.end()
	sgl.texture(font.view, font.sampler)
	sgl.begin_quads()
	annot_draw(tab_id, x, y, w, h) // comment mode and markers (browser_annotate.odin)
	browser_act_draw(tab_id, x, y, w, h) // a ring where an agent clicked (browser_act.odin)
}

// The tab closed (drop_term).
browser_drop :: proc(tab_id: u64) {
	b := browsers[tab_id]
	if b == nil do return
	if id := b.cef; id != 0 {
		b.cef = 0 // as browser_unload: on_cef_closed finds nothing
		dh_cef_close(id)
	}
	browser_free_page(b)
	delete(b.url)
	delete(b.title)
	free(b)
	delete_key(&browsers, tab_id)
}

// Quit: every browser closes, then CEF shuts down (before sokol's).
browser_shutdown :: proc() {
	if cef_state == .Running do dh_cef_shutdown()
	cef_state = .Failed
}

// ---- input (event(): after Deckhand's own shortcuts and open widgets) ----

@(private = "file")
cef_mods :: proc(m: u32, buttons: c.int) -> c.int {
	r := buttons
	if m & sapp.MODIFIER_SHIFT != 0 do r |= CEF_FLAG_SHIFT
	if m & sapp.MODIFIER_CTRL != 0 do r |= CEF_FLAG_CONTROL
	if m & sapp.MODIFIER_ALT != 0 do r |= CEF_FLAG_ALT
	if m & sapp.MODIFIER_SUPER != 0 do r |= CEF_FLAG_COMMAND
	return r
}

@(private = "file")
in_page :: proc(p: [4]f32, x, y: f32) -> bool {
	return p.z > 0 && x >= p.x && y >= p.y && x < p.x + p.z && y < p.y + p.w
}

// Forwards the event to the browser pane p shows. True if it took it. As for
// an editor tab (editor_event): keys only while no widget has the keyboard;
// the mouse not under the palette, a menu or a sheet, nor in Atlas's drawer.
browser_event :: proc(p: ^core.Pane, e: ^sapp.Event) -> bool {
	b := pane_browser(p)
	if b == nil do return false
	r := pane_rect(p)
	// the toolbar: Back, Forward, Reload / Stop, the URL field (browser_nav.odin)
	if e.type == .MOUSE_DOWN && !(palette_is_open() || menu.open || settings_open() || shortcuts_open() || setup_open() || job_sheet_open()) && browser_bar_click(p, e) do return true
	if b.cef == 0 {
		// the page closed itself: its Reload button (ui.odin) opens it again
		if e.type == .MOUSE_DOWN && b.closed_by_page && cinside("browser_reload", e.mouse_x, e.mouse_y) {
			ui_do(core.Browser_Reload{b.tab_id})
			return true
		}
		return false
	}
	vx, vy := c.int((e.mouse_x - r.x) / app.dpi), c.int((e.mouse_y - r.y) / app.dpi)
	button: c.int = e.mouse_button == .RIGHT ? 2 : e.mouse_button == .MIDDLE ? 1 : 0
	flag: c.int = button == 0 ? CEF_FLAG_LEFT_BUTTON : button == 1 ? 1 << 5 : 1 << 6
	// drawer.odin's over_overlay (file-private there): the palette, a menu, a popover, a sheet;
	// the job sheet is modal (main.odin's event() takes its input first; this holds without that)
	overlay := palette_is_open() || menu.open || settings_open() || shortcuts_open() || setup_open() || job_sheet_open()
	covered := overlay || (state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y))
	#partial switch e.type {
	case .KEY_DOWN, .CHAR, .KEY_UP:
		if state.focus_widget != "" do return false
	case .MOUSE_DOWN, .MOUSE_SCROLL:
		if covered do return false
	case .MOUSE_MOVE:
		if covered && b.buttons == 0 do return false
	}
	#partial switch e.type {
	case .MOUSE_DOWN, .MOUSE_UP, .MOUSE_MOVE, .MOUSE_SCROLL:
		b.last_x, b.last_y = vx, vy
	}
	#partial switch e.type {
	case .MOUSE_DOWN:
		if !in_page(r, e.mouse_x, e.mouse_y) do return false
		// a click in the page takes the keyboard back; a sliding drawer goes away
		if state.home_open && !state.layout.drawer_pinned do ui_do(core.Set_Home{open = false})
		if state.focus_widget != "" do ui_do(core.Set_Focus{""})
		ime_cancel()
		b.buttons |= flag
		browser_act_user_input(b.tab_id) // an agent acting here pauses (browser_act.odin)
		browser_page_input(b.tab_id) // the user's own click (browser_polish.odin: downloads)
		dh_cef_mouse_click(b.cef, vx, vy, cef_mods(e.modifiers, b.buttons), button, 0, c.int(max(app.clicks, 1)))
		return true
	case .MOUSE_UP:
		if b.buttons & flag == 0 do return false
		b.buttons &~= flag
		dh_cef_mouse_click(b.cef, vx, vy, cef_mods(e.modifiers, b.buttons), button, 1, c.int(max(app.clicks, 1)))
		return true
	case .MOUSE_MOVE:
		if !in_page(r, e.mouse_x, e.mouse_y) && b.buttons == 0 do return false
		dh_cef_mouse_move(b.cef, vx, vy, cef_mods(e.modifiers, b.buttons), 0)
		return in_page(r, e.mouse_x, e.mouse_y)
	case .MOUSE_LEAVE:
		dh_cef_mouse_move(b.cef, b.last_x, b.last_y, cef_mods(e.modifiers, b.buttons), 1)
		return false // Deckhand's hover goes too
	case .MOUSE_SCROLL:
		if !in_page(r, e.mouse_x, e.mouse_y) do return false
		// sokol's deltas are lines-ish; Chromium wants pixels
		dh_cef_wheel(b.cef, vx, vy, cef_mods(e.modifiers, 0), c.int(e.scroll_x * 40), c.int(e.scroll_y * 40))
		return true
	case .KEY_DOWN:
		if e.modifiers & sapp.MODIFIER_SUPER != 0 do return false // Deckhand's shortcuts (SPIKE: no ⌘C/V to the page yet)
		code, ch, known := mac_key(e.key_code, e.modifiers)
		if !known do return true // no macOS key code for it: never sent as another key
		browser_act_user_input(b.tab_id) // an agent acting here pauses (browser_act.odin)
		b.held += {int(code)}
		b.held_ch[code] = ch
		#partial switch e.key_code {
		case .ENTER, .KP_ENTER, .SPACE: browser_page_input(b.tab_id) // a key that activates (downloads: once)
		}
		// SPIKE: Chromium shows the page no keydown for a modifier alone sent
		// this way (nor as KEYDOWN); step 1.2 passes AppKit's flagsChanged through
		dh_cef_key(b.cef, CEF_KEY_RAWKEYDOWN, code, cef_mods(e.modifiers, 0) | modifier_flag(code), ch, ch)
		return true
	case .CHAR:
		if e.modifiers & sapp.MODIFIER_SUPER != 0 do return false
		if e.char_code < 0x20 && e.char_code != 13 && e.char_code != 9 do return true // control keys went as key downs
		dh_cef_key(b.cef, CEF_KEY_CHAR, 0, cef_mods(e.modifiers, 0), u16(e.char_code), u16(e.char_code))
		return true
	case .KEY_UP:
		if e.modifiers & sapp.MODIFIER_SUPER != 0 do return false
		code, ch, known := mac_key(e.key_code, e.modifiers)
		if !known do return true
		b.held -= {int(code)}
		dh_cef_key(b.cef, CEF_KEY_UP, code, cef_mods(e.modifiers, 0), ch, ch)
		return true
	}
	return false
}

// A modifier key going down carries its own flag, as AppKit's flagsChanged does.
@(private = "file")
modifier_flag :: proc(code: c.int) -> c.int {
	switch code {
	case 56, 60: return CEF_FLAG_SHIFT
	case 59, 62: return CEF_FLAG_CONTROL
	case 58, 61: return CEF_FLAG_ALT
	case 55, 54: return CEF_FLAG_COMMAND
	}
	return 0
}

// sokol key code -> macOS virtual key code (Carbon kVK_*) and the
// character AppKit gives that key unshifted; known=false: no such key here
// (it is not sent: code 0 would be kVK_ANSI_A). SPIKE: a US layout table;
// step 1.2 passes the NSEvent's own fields.
mac_key :: proc(k: sapp.Keycode, mods: u32) -> (code: c.int, ch: u16, known: bool) {
	LETTERS := [26]c.int{0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6}
	DIGITS := [10]c.int{29, 18, 19, 20, 21, 23, 22, 26, 28, 25}
	FKEYS := [12]c.int{122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111}
	shift := mods & sapp.MODIFIER_SHIFT != 0
	#partial switch k {
	case .A ..= .Z:
		i := int(k) - int(sapp.Keycode.A)
		return LETTERS[i], u16(shift ? 'A' + i : 'a' + i), true
	case ._0 ..= ._9:
		i := int(k) - int(sapp.Keycode._0)
		return DIGITS[i], u16('0' + i), true
	case .F1 ..= .F12:
		i := int(k) - int(sapp.Keycode.F1)
		return FKEYS[i], u16(0xF704 + i), true // NSF1FunctionKey...
	case .ENTER, .KP_ENTER: return 36, 13, true
	case .TAB: return 48, 9, true
	case .SPACE: return 49, ' ', true
	case .BACKSPACE: return 51, 0x7f, true
	case .ESCAPE: return 53, 0x1b, true
	case .DELETE: return 117, 0xF728, true
	case .LEFT: return 123, 0xF702, true
	case .RIGHT: return 124, 0xF703, true
	case .DOWN: return 125, 0xF701, true
	case .UP: return 126, 0xF700, true
	case .HOME: return 115, 0xF729, true
	case .END: return 119, 0xF72B, true
	case .PAGE_UP: return 116, 0xF72C, true
	case .PAGE_DOWN: return 121, 0xF72D, true
	case .PERIOD: return 47, '.', true
	case .COMMA: return 43, ',', true
	case .SLASH: return 44, '/', true
	case .MINUS: return 27, '-', true
	case .SEMICOLON: return 41, ';', true
	case .APOSTROPHE: return 39, '\'', true
	case .LEFT_BRACKET: return 33, '[', true
	case .RIGHT_BRACKET: return 30, ']', true
	case .BACKSLASH: return 42, '\\', true
	case .EQUAL: return 24, '=', true
	case .GRAVE_ACCENT: return 50, '`', true
	// modifiers alone (no character)
	case .LEFT_SHIFT: return 56, 0, true
	case .LEFT_CONTROL: return 59, 0, true
	case .LEFT_ALT: return 58, 0, true
	case .LEFT_SUPER: return 55, 0, true
	case .RIGHT_SHIFT: return 60, 0, true
	case .RIGHT_ALT: return 61, 0, true
	case .RIGHT_CONTROL: return 62, 0, true
	case .RIGHT_SUPER: return 54, 0, true
	case .CAPS_LOCK: return 57, 0, true
	}
	return 0, 0, false
}

// ---- test mode (autotest.odin hands these lines over) ----
//
//   web_open URL               a browser tab in the current session ($last); a relative path
//                              becomes a file:// URL under the repo (tests/web/…)
//   web_waitpaint [MS]         until the page painted at least once (default 10 s)
//   web_title TEXT [MS]        until the page title contains TEXT (default 5 s)
//   web_pixel X Y RRGGBB [MS]  until the page pixel at logical X,Y (page coordinates)
//                              is RRGGBB (±8 per channel)
//   web_click X Y              a left click at page X,Y, through Deckhand's event path
//   web_scroll DY X Y          the wheel at page X,Y (DY lines, as `scroll`)
//   web_js CODE                run JavaScript in the page (no result)
//   web_stats                  log the paint path, first paint and CEF start times
//   web_assert opens N         browsers created for the tab on screen so far
//   web_assert message TEXT    the text shown instead of the page ("-" = none)
//   web_assert focused yes|no  whether the page has Deckhand's keyboard
//   web_assert overwrites N    paints written into the texture the last drawn frame sampled
//   web_assert inflight_writes N   slots handed to CEF while a GPU frame not completed yet
//                              samples them (all tabs; DECKHAND_TEST_GPU_LAG_MS slows the GPU)
//   web_assert surfaces N      ring surfaces alive for the tab on screen (3: one ring)
//   web_assert shown held      the slot on screen is Deckhand's, not the producer's
//   web_assert freed           no browser tabs: no ring surfaces, local channels (open or
//                              draining) or images left
//   web_assert rings_max N     rings created for the tab since web_mark are at most N
//   web_assert surfaces_peak_max N   ring surfaces alive at once since web_mark, at most N
//   web_assert pumps_max N     CEF message-loop pumps since web_mark are at most N
//   web_mark                   remember the pump count (no browser needed)
//   web_mouse down|up|leave X Y   one mouse event at page X,Y through Deckhand's event path
//   web_keydown LETTER         a key press without its release (KEY_DOWN + CHAR)
//   web_comment X Y W H TEXT   the comment picker's stub (comments.odin): a comment on the page
//                              area X,Y W×H (page px) of the tab on screen, cropped from its frame

Browser_Wait :: struct {
	kind:     string, // "" = none
	text:     string,
	x, y:     c.int,
	rgb:      u32,
	deadline: time.Tick,
}
browser_wait: Browser_Wait
browser_pump_mark: u64 // web_mark

@(private = "file")
wait_set :: proc(kind: string, ms: f64, text := "") {
	delete(browser_wait.text)
	browser_wait.kind = kind
	browser_wait.text = strings.clone(text)
	browser_wait.deadline = time.tick_add(time.tick_now(), time.Duration(ms * f64(time.Millisecond)))
}

@(private = "file")
arg_ms :: proc(args: []string, i: int, def: f64) -> f64 {
	if i < len(args) {
		v, ok := strconv.parse_f64(args[i])
		if ok do return v
	}
	return def
}

@(private = "file")
pixel_at :: proc(b: ^Browser, x, y: c.int) -> (u32, bool) {
	// the slot on screen (what the last frame drew)
	if b.cef == 0 || b.ring.shown_gen == 0 do return 0, false
	px, py := int(f32(x) * app.dpi), int(f32(y) * app.dpi)
	if px >= b.content_w || py >= b.content_h do return 0, false // headroom, not the page
	rgb: u32
	if dh_frames_pixel(b.tab_id, b.ring.shown_gen, c.int(b.ring.shown_slot), c.int(f32(x) * app.dpi), c.int(f32(y) * app.dpi), &rgb) == 0 do return 0, false
	return rgb, true
}

@(private = "file")
rgb_near :: proc(a, b: u32) -> bool {
	for s in ([]u32{0, 8, 16}) {
		d := int((a >> s) & 0xFF) - int((b >> s) & 0xFF)
		if d < -8 || d > 8 do return false
	}
	return true
}

// A pending web_* wait: true when the script may go on. fail gets the
// message of a timeout.
browser_wait_done :: proc(fail: proc(msg: string)) -> bool {
	w := &browser_wait
	if w.kind == "" do return true
	b := script_browser()
	done := false
	got := ""
	if b != nil do switch w.kind {
	case "paint":
		done = b.painted > 0 && b.ring.shown_gen != 0
		got = fmt.tprintf("%d frames", b.painted)
	case "title":
		done = strings.contains(b.title, w.text)
		got = b.title
	case "pixel":
		px, ok := pixel_at(b, w.x, w.y)
		done = ok && rgb_near(px, w.rgb)
		got = ok ? fmt.tprintf("%06x", px) : "no frame"
	}
	if done {
		fmt.printfln("[browser] %s reached: %s (%.0f ms after open)", w.kind, got, b != nil ? time.duration_milliseconds(time.tick_since(b.opened_at)) : 0)
	} else if time.tick_diff(w.deadline, time.tick_now()) > 0 {
		fail(fmt.tprintf("ASSERT FAILED web_%s: want %q / %06x, got %q", w.kind, w.text, w.rgb, got))
	} else do return false
	w.kind = ""
	return true
}

// One web_* line. ok=false: a failure message for the script.
// The script's page: the focused tab's, else one on screen in another pane of the session (a
// split: the keyboard in a shell beside it).
script_browser :: proc() -> ^Browser {
	if b := tab_browser(); b != nil do return b
	if s := core.cur(); s != nil do for &p in s.panes do if b := pane_browser(&p); b != nil do return b
	return nil
}

browser_script :: proc(cmd: string, args: []string, rest: string) -> (msg: string, ok: bool) {
	b := script_browser()
	switch cmd {
	case "web_open":
		url := rest
		if !strings.contains(url, "://") {
			cwd, _ := os.get_working_directory(context.temp_allocator)
			url = fmt.tprintf("file://%s/%s", cwd, url)
		}
		// the test's own session: the one on screen (a user's action)
		cs := core.cur()
		if cs == nil do return "web_open: no session", false
		r := client_call(core.Browser_Open{session = cs.id, url = url}) // the user's (tabhost_route.odin)
		if !r.ok do return fmt.tprintf("web_open: %s", r.error), false
		autotest.last_created = r.created_id // $last
		return "", true
	case "web_waitpaint":
		wait_set("paint", arg_ms(args, 0, 10000))
		return "", true
	case "web_title":
		if len(args) == 0 do return "web_title TEXT [MS]", false
		// TEXT may have spaces; a last word that is a number is the timeout
		text, ms := rest, 5000.0
		if len(args) > 1 {
			if v, ok := strconv.parse_f64(args[len(args) - 1]); ok {
				ms = v
				text = strings.trim_space(rest[:strings.last_index(rest, args[len(args) - 1])])
			}
		}
		wait_set("title", ms, text)
		return "", true
	case "web_pixel":
		if len(args) < 3 do return "web_pixel X Y RRGGBB [MS]", false
		x, _ := strconv.parse_f64(args[0])
		y, _ := strconv.parse_f64(args[1])
		rgb: u32
		for r in args[2] {
			d: u32
			switch r {
			case '0' ..= '9': d = u32(r - '0')
			case 'a' ..= 'f': d = u32(r - 'a' + 10)
			case 'A' ..= 'F': d = u32(r - 'A' + 10)
			}
			rgb = rgb << 4 | d
		}
		wait_set("pixel", arg_ms(args, 3, 5000))
		browser_wait.x, browser_wait.y, browser_wait.rgb = c.int(x), c.int(y), rgb
		return "", true
	case "web_click", "web_scroll":
		if b == nil do return fmt.tprintf("%s: no browser tab on screen", cmd), false
		n := cmd == "web_click" ? 2 : 3
		if len(args) < n do return fmt.tprintf("%s: arguments", cmd), false
		v: [3]f64
		for i in 0 ..< n {
			neg := strings.has_prefix(args[i], "-")
			v[i], _ = strconv.parse_f64(neg ? args[i][1:] : args[i])
			if neg do v[i] = -v[i]
		}
		if cmd == "web_click" {
			r := tab_rect(b.tab_id)
			x, y := r.x + f32(v[0]) * app.dpi, r.y + f32(v[1]) * app.dpi
			app.clicks = 1
			e := sapp.Event{type = .MOUSE_MOVE, mouse_x = x, mouse_y = y}
			event(&e)
			e = {type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y}
			event(&e)
			e = {type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y}
			event(&e)
		} else {
			r := tab_rect(b.tab_id)
			e := sapp.Event{type = .MOUSE_SCROLL, scroll_y = f32(v[0]), mouse_x = r.x + f32(v[1]) * app.dpi, mouse_y = r.y + f32(v[2]) * app.dpi}
			event(&e)
		}
		return "", true
	case "web_js":
		if b == nil || b.cef == 0 do return "web_js: no browser", false
		dh_cef_exec_js(b.cef, strings.clone_to_cstring(rest, context.temp_allocator))
		return "", true
	case "web_mark":
		gpu, cpu, pumps, dropped: u64
		first_ms: f64
		dh_cef_stats(0, &gpu, &cpu, &first_ms, &pumps, &dropped)
		browser_pump_mark = pumps
		for _, x in browsers do x.rings_mark, x.surf_peak, x.bytes_mark = x.rings_made, int(dh_frames_surface_count(x.tab_id)), x.ring_bytes
		fmt.printfln("[browser] mark: %d pumps so far", pumps)
		return "", true
	case "web_mouse":
		if b == nil do return "web_mouse: no browser tab on screen", false
		if len(args) < 3 do return "web_mouse down|up|leave X Y", false
		x, _ := strconv.parse_f64(args[1])
		y, _ := strconv.parse_f64(args[2])
		r := tab_rect(b.tab_id)
		e := sapp.Event{mouse_button = .LEFT, mouse_x = r.x + f32(x) * app.dpi, mouse_y = r.y + f32(y) * app.dpi}
		switch args[0] {
		case "down": e.type = .MOUSE_DOWN
		case "up": e.type = .MOUSE_UP
		case "leave": e.type = .MOUSE_LEAVE
		case: return "web_mouse down|up|leave X Y", false
		}
		app.clicks = 1
		event(&e)
		return "", true
	case "web_comment":
		if b == nil do return "web_comment: no browser tab on screen", false
		if len(args) < 5 do return "web_comment X Y W H TEXT", false
		box: [4]int
		for i in 0 ..< 4 {
			v, ok := strconv.parse_int(args[i])
			if !ok do return "web_comment X Y W H TEXT", false
			box[i] = v
		}
		text := rest
		for _ in 0 ..< 4 do text = strings.trim_left_space(text[strings.index_byte(text, ' ') + 1:])
		id, err := browser_comment_add(b.tab_id, box, "", text)
		if id == 0 do return fmt.tprintf("web_comment: %s", err), false
		autotest.last_created = id // $last
		return "", true
	case "web_keydown":
		if len(args) < 1 || len(args[0]) != 1 || args[0][0] < 'a' || args[0][0] > 'z' do return "web_keydown LETTER", false
		r := args[0][0]
		e := sapp.Event{type = .KEY_DOWN, key_code = sapp.Keycode(int(sapp.Keycode.A) + int(r - 'a'))}
		event(&e)
		e = {type = .CHAR, char_code = u32(r)}
		event(&e)
		return "", true
	case "web_assert":
		if len(args) == 2 && args[0] == "pumps_max" {
			gpu, cpu, pumps, dropped: u64
			first_ms: f64
			dh_cef_stats(0, &gpu, &cpu, &first_ms, &pumps, &dropped)
			want, _ := strconv.parse_f64(args[1])
			n := pumps - browser_pump_mark
			if f64(n) > want do return fmt.tprintf("ASSERT FAILED web_assert pumps_max: %d pumps since the mark, want at most %s", n, args[1]), false
			fmt.printfln("[browser] assert ok: %d pumps since the mark (at most %s)", n, args[1])
			return "", true
		}
		if len(args) == 1 && args[0] == "freed" {
			n, chans := int(dh_frames_surface_total_local()), int(dh_frames_local_chans())
			if n != 0 || chans != 0 || browser_images != 0 || len(browsers) != 0 do return fmt.tprintf("ASSERT FAILED web_assert freed: %d surfaces, %d channels, %d images, %d browsers", n, chans, browser_images, len(browsers)), false
			fmt.println("[browser] assert ok: no browser surfaces, channels, images or tabs left")
			return "", true
		}
		if b == nil do return "web_assert: no browser tab on screen", false
		if len(args) < 2 do return "web_assert opens|message|focused|overwrites|surfaces|shown|pumps_max VALUE", false
		want := strings.trim_space(rest[len(args[0]):])
		got: string
		switch args[0] {
		case "opens": got = fmt.tprint(b.opens)
		case "message": got = b.message != "" ? b.message : "-"
		case "focused": got = b.focused ? "yes" : "no"
		case "hidden": got = b.hidden ? "yes" : "no" // CEF told the page is hidden (no pane shows it)
		case "view": got = fmt.tprintf("%dx%d", b.view_w, b.view_h) // its CEF view, logical px: its pane's
		case "overwrites": got = fmt.tprint(b.overwrites)
		case "inflight_writes": got = fmt.tprint(dh_frames_inflight_writes())
		case "surfaces": got = fmt.tprint(dh_frames_surface_count(b.tab_id))
		case "rings_max", "surfaces_peak_max":
			// at most N since web_mark
			n := args[0] == "rings_max" ? b.rings_made - b.rings_mark : b.surf_peak
			lim, _ := strconv.parse_int(want)
			if n > lim do return fmt.tprintf("ASSERT FAILED web_assert %s: %d, want at most %d", args[0], n, lim), false
			fmt.printfln("[browser] assert ok: %s %d (at most %d)", args[0], n, lim)
			return "", true
		case "shown":
			// the slot on screen is Deckhand's (the producer cannot have it)
			st := b.ring.shown_gen != 0 ? dh_frames_local_slot_state(b.tab_id, b.ring.shown_gen, c.int(b.ring.shown_slot)) : -1
			got = st == FRAMES_SLOT_DECKHAND ? "held" : fmt.tprintf("state %d", st)
		case: return fmt.tprintf("web_assert: unknown %s", args[0]), false
		}
		if got != want do return fmt.tprintf("ASSERT FAILED web_assert %s: got %q, want %q", args[0], got, want), false
		fmt.printfln("[browser] assert ok: %s = %s", args[0], got)
		return "", true
	case "web_stats":
		if b == nil do return "web_stats: no browser tab on screen", false
		gpu, cpu, pumps, dropped: u64
		first_ms: f64
		dh_cef_stats(b.cef, &gpu, &cpu, &first_ms, &pumps, &dropped)
		g := ring_gen(&b.ring, b.ring.shown_gen)
		gw, gh := g != nil ? g.w : 0, g != nil ? g.h : 0
		bytes := dh_frames_surface_bytes(b.tab_id)
		fmt.printfln("[browser] stats: paint path %s (gpu frames %d, cpu frames %d, dropped %d, slots reused unshown %d); cef start %.0f ms; first paint %.0f ms after open (browser created -> paint %.0f ms); pumps %d; dpi %.1f; frame %dx%d px in ring gen %d %dx%d px, %d surfaces %.1f MB; rings made %d (%d since mark, %.0f MB allocated since mark), peak %d surfaces",
			gpu > 0 ? "OnAcceleratedPaint" : "OnPaint", gpu, cpu, dropped, dh_frames_local_reclaimed(b.tab_id), cef_start_ms, time.duration_milliseconds(b.first_paint), first_ms, pumps, app.dpi, b.content_w, b.content_h, b.ring.shown_gen, gw, gh, dh_frames_surface_count(b.tab_id), f64(bytes) / (1024 * 1024), b.rings_made, b.rings_made - b.rings_mark, f64(b.ring_bytes - b.bytes_mark) / (1024 * 1024), b.surf_peak)
		return "", true
	}
	return fmt.tprintf("unknown command %s", cmd), false
}

// A run with DECKHAND_DEBUG_BROWSER=URL opens a browser tab once a session
// is on screen (SPIKE: the only way outside test mode).
browser_debug_tick :: proc() {
	@(static) done: bool
	if done do return
	url := core.hook_env(.Debug_Browser)
	if url == "" {
		done = true
		return
	}
	cs := core.cur()
	if cs == nil do return
	done = true
	client_call(core.Browser_Open{session = cs.id, url = url}) // the session on screen: as if the user opened it there
}


// The Reload button under "The page closed itself" (ui.odin's centre).
browser_reload_button :: proc() {
	button(cid("browser_reload"), "Reload", true, false)
}

// The folder that holds the browser's profile, cache and log (its "browser" folder).
@(private = "file")
browser_root :: proc(allocator := context.allocator) -> string {
	root := core.home_root != "" ? core.home_root : "build/test-data"
	if !filepath.is_abs(root) {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		root, _ = filepath.join({cwd, root}, context.temp_allocator)
	}
	return strings.clone(root, allocator)
}

// The browser's own files (profile, cookies, cache, log): uploads never take a file from there.
browser_profile_root :: proc(allocator := context.allocator) -> string {
	p, _ := filepath.join({browser_root(context.temp_allocator), "browser"}, allocator)
	return p
}
