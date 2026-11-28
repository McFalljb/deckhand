package main

// The quit paths as a table (main.odin's quit_route; docs/plans/background-core.md §10.3 M4-D):
// ⌘Q, the Dock's Quit, logout and Stop All, in process and with a separate core.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "core"

@(test)
quit_paths_table :: proc(t: ^testing.T) {
	Row :: struct {
		from:     Quit_From,
		separate: bool,
		quitting: bool,
		want:     Quit_Do,
	}
	rows := []Row {
		{.Menu, false, false, .Ask_Core}, // in process: ⌘Q asks the core (it confirms, then the holder's handover)
		{.Dock, false, false, .Ask_Core}, // the Dock's Quit is ⌘Q (it used to skip the handover)
		{.Logout, false, false, .Terminate}, // logout: cleanup saves, today's restore follows
		{.Stop_All, false, false, .Stop_All},
		{.Menu, true, false, .Close_Window}, // a separate core: the window goes, the sessions run on
		{.Dock, true, false, .Close_Window},
		{.Logout, true, false, .Terminate}, // the core saves and exits on its own SIGTERM
		{.Stop_All, true, false, .Stop_All}, // the core stops everything, then tells the window to quit
		// once a quit went through, macOS's terminate after the window closed goes ahead
		{.Dock, false, true, .Terminate},
		{.Dock, true, true, .Terminate},
		{.Logout, true, true, .Terminate},
	}
	for r in rows {
		testing.expectf(t, quit_route(r.from, r.separate, r.quitting) == r.want, "%v separate=%v quitting=%v: %v, want %v", r.from, r.separate, r.quitting, quit_route(r.from, r.separate, r.quitting), r.want)
	}
}

// A separate core that keeps stopping (client_core_tick): at most RECONNECTS_MAX reconnects in a
// minute, then the window gives up; a minute later it may again.
@(test)
reconnect_limit :: proc(t: ^testing.T) {
	t0 := time.Tick{_nsec = 1_000_000_000}
	since: time.Tick
	n: int
	for i in 0 ..< RECONNECTS_MAX do testing.expectf(t, reconnect_allowed(&since, &n, time.tick_add(t0, time.Duration(i) * time.Second)), "reconnect %d", i + 1)
	testing.expect(t, !reconnect_allowed(&since, &n, time.tick_add(t0, 30 * time.Second)), "one too many within the minute")
	testing.expect(t, reconnect_allowed(&since, &n, time.tick_add(t0, RECONNECTS_PER)), "a minute later")
}

// One prompt per displacement: the alert's modal loop runs the window's timer, whose
// client_core_tick must neither ask again nor dial before the user answers.
@(test)
viewed_asks_once :: proc(t: ^testing.T) {
	@(static) asks, nested_reconnects: int
	@(static) depth: int
	asks, nested_reconnects, depth = 0, 0, 0
	saved_ask := client_ask
	defer client_ask = saved_ask
	client_ask = proc(title, text, yes, no: string) -> bool {
		asks += 1
		depth += 1
		defer depth -= 1
		if depth <= 3 { 	// the modal loop's timer turns
			before := client.reconnects
			client_core_tick()
			client_core_tick()
			nested_reconnects += client.reconnects - before
		}
		return false // Quit
	}
	saved_lost, saved_gave, saved_quit := client.lost, client.gave_up, core.app_quitting
	defer {
		client.lost, client.gave_up, core.app_quitting = saved_lost, saved_gave, saved_quit
		client.asking = false
	}
	client.lost, client.gave_up, core.app_quitting = true, false, false
	client_core_viewed("Mac Chrome", browser = true)
	client_core_tick()
	testing.expect_value(t, asks, 1)
	testing.expect_value(t, nested_reconnects, 0)
	testing.expect_value(t, client.viewed_from, "")
	testing.expect(t, client.gave_up, "Quit: the window closes, once")
}

// The reconnect tests' setup: a lost link, nothing tried yet, the attempt and the alert swapped.
@(private = "file")
Reconnect_Fake :: struct {
	tries:  int,
	fail:   int, // the first `fail` attempts fail
	final:  bool, // ...as a dial that no core answered
	why:    string,
	alerts: int,
	alert:  string,
}

@(private = "file")
fake: Reconnect_Fake

@(private = "file")
reconnect_fake :: proc(fail: int, why: string, final := false) -> (restore: proc()) {
	fake = {fail = fail, why = why, final = final}
	@(static) saved_try: proc() -> (string, bool)
	@(static) saved_alert: proc(title, text, button: string)
	saved_try, saved_alert = client_reconnect_try, client_alert
	client_reconnect_try = proc() -> (string, bool) {
		fake.tries += 1
		if fake.tries <= fake.fail do return fake.why, fake.final
		client.lost = false
		return "", false
	}
	client_alert = proc(title, text, button: string) {
		fake.alerts += 1
		fake.alert = fmt.aprint(text)
	}
	client.lost, client.gave_up, client.asking, core.app_quitting = true, false, false, false
	client.reconnects, client.reconnects_since = 0, {}
	client_outage_reset()
	return proc() {
		client_reconnect_try, client_alert = saved_try, saved_alert
		client.lost, client.gave_up, client.asking, core.app_quitting = false, false, false, false
		client.reconnects, client.reconnects_since = 0, {}
		client_outage_reset()
		delete(fake.alert)
	}
}

// A reconnect that fails once (the core attached the window, then sent no state) and then works:
// the window stays (it used to give up and close at the first failure).
@(test)
reconnect_fails_once_then_works :: proc(t: ^testing.T) {
	restore := reconnect_fake(1, "Deckhand's background core sent no state")
	defer restore()
	t0 := time.tick_now()
	client_core_tick(t0)
	testing.expect_value(t, fake.tries, 1)
	testing.expect(t, !client.gave_up, "one failed reconnect does not close the window")
	testing.expect(t, client.lost, "still lost: it tries again")
	client_core_tick(time.tick_add(t0, 10 * time.Millisecond))
	testing.expect_value(t, fake.tries, 1) // backing off: not in a tight loop
	for i in 1 ..= 40 {
		if !client.lost do break
		client_core_tick(time.tick_add(t0, time.Duration(i) * 100 * time.Millisecond))
	}
	testing.expect_value(t, fake.tries, 2)
	testing.expect(t, !client.lost, "attached again")
	testing.expect(t, !client.gave_up)
	testing.expect_value(t, fake.alerts, 0)
}

// A core that keeps failing the window: tried again with a growing backoff, then given up on once,
// with the reason, before RECONNECTS_MAX attempts in the minute are spent or 15 s have passed.
@(test)
reconnect_gives_up_after_the_limit :: proc(t: ^testing.T) {
	restore := reconnect_fake(1000, "Deckhand's background core sent no state")
	defer restore()
	t0 := time.tick_now()
	for i in 0 ..< 400 { 	// 40 s in 100 ms turns
		if client.gave_up do break
		client_core_tick(time.tick_add(t0, time.Duration(i) * 100 * time.Millisecond))
	}
	testing.expect(t, client.gave_up)
	testing.expectf(t, fake.tries > 1 && fake.tries <= RECONNECTS_MAX, "tries %d", fake.tries)
	testing.expect_value(t, fake.alerts, 1)
	testing.expectf(t, strings.contains(fake.alert, "sent no state"), "the alert says why: %q", fake.alert)
}

// No core answers at all (the dial waited its 15 s and launched cores meanwhile): given up at once.
@(test)
reconnect_no_core_gives_up :: proc(t: ^testing.T) {
	restore := reconnect_fake(1000, "Deckhand's background core did not start within 15 s", final = true)
	defer restore()
	client_core_tick(time.tick_now())
	testing.expect_value(t, fake.tries, 1)
	testing.expect(t, client.gave_up)
	testing.expect_value(t, fake.alerts, 1)
}

// The give-up's reason, and the transport's reason for the lost link, are in window.log and in
// the alert; a secret-shaped string in them is redacted on disk.
@(test)
reconnect_give_up_logged :: proc(t: ^testing.T) {
	dir := test_dir("wlog")
	saved_log := window_log
	window_log = {}
	defer {
		core.log_file_close(&window_log)
		window_log = saved_log
	}
	path := fmt.tprintf("%s/window.log", dir)
	testing.expect(t, core.log_file_open(&window_log, path))
	restore := reconnect_fake(1000, "the background core refused this window: token=abcdefghijklmnopqrstuvwx", final = true)
	defer restore()
	client_core_lost_why("the connection ended: closed by the other side")
	client.lost = true
	client_core_tick(time.tick_now())
	testing.expect(t, client.gave_up)
	b, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	text := string(b)
	testing.expectf(t, strings.contains(text, "cannot reconnect to the background core"), "give-up logged: %q", text)
	testing.expectf(t, strings.contains(text, "closed by the other side"), "the transport's reason logged: %q", text)
	testing.expectf(t, !strings.contains(text, "abcdefghijklmnopqrstuvwx"), "redacted: %q", text)
	testing.expectf(t, strings.contains(text, "[REDACTED]"), "redacted: %q", text)
	testing.expectf(t, strings.contains(fake.alert, "closed by the other side"), "the alert has the transport's reason: %q", fake.alert)
}

// A launch or install that fails (a transient error: the bundle being replaced, a full disk) is
// one failed attempt, tried again; only a dial that waited its 15 s with no core is final.
// Runs the real reconnect and dial over an empty, private runtime dir: no core is reached.
@(test)
reconnect_launch_error_retries :: proc(t: ^testing.T) {
	@(static) launches: int
	launches = 0
	run := test_dir("rl-run")
	saved_env := os.get_env("DECKHAND_RUNTIME_DIR", context.temp_allocator)
	os.set_env("DECKHAND_RUNTIME_DIR", run)
	defer os.set_env("DECKHAND_RUNTIME_DIR", saved_env)
	saved_launch, saved_alert := client_launch_hook, client_alert
	defer client_launch_hook, client_alert = saved_launch, saved_alert
	client_launch_hook = proc(run, data: string, from_tab: bool) -> string {
		launches += 1
		return "cannot install Deckhand Core.app: the disk is full"
	}
	client_alert = proc(title, text, button: string) {}
	saved_sock := client.sock
	client.sock = nil
	defer client.sock = saved_sock
	client.lost, client.gave_up, client.asking, core.app_quitting = true, false, false, false
	client.reconnects, client.reconnects_since = 0, {}
	client_outage_reset()
	defer {
		client.lost, client.gave_up = false, false
		client.reconnects, client.reconnects_since = 0, {}
		client_outage_reset()
	}
	why, final := client_core_reconnect()
	testing.expect_value(t, launches, 1)
	testing.expectf(t, strings.contains(why, "disk is full"), "why: %q", why)
	testing.expect(t, !final, "a launch error is not final")
	client_core_tick(time.tick_now())
	testing.expect(t, !client.gave_up, "the window stays and tries again")
	testing.expect(t, client.lost)
}

// An outage whose clock jumped (the Mac slept, no tick ran): its 15 s start again on wake, so a
// window that slept through a core restart is not given up on at its first try after.
@(test)
reconnect_outage_survives_sleep :: proc(t: ^testing.T) {
	restore := reconnect_fake(2, "Deckhand's background core sent no state")
	defer restore()
	t0 := time.tick_now()
	client_core_tick(t0) // fails: the outage starts at t0
	testing.expect(t, !client.gave_up)
	client_core_tick(time.tick_add(t0, 40 * time.Second)) // the next tick, after a sleep: fails again
	testing.expect(t, !client.gave_up, "not given up across a sleep: its 15 s start again")
	testing.expect_value(t, fake.tries, 2)
}
