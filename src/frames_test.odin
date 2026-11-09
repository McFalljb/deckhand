package main

// App tabs' frame channel, the parts that need no GPU or second process
// (`./build.sh test`): the Mach messages' layout, the key and sender checks,
// the drop rules, the ring's generation bookkeeping, key names for input,
// and the app commands' parsing and permissions. The live channel is the
// app-tab scene (tests/scripts/app-tab.sh).

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
rd32 :: proc(b: []u8, off: int) -> u32 {return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24}
@(private = "file")
rd64 :: proc(b: []u8, off: int) -> u64 {return u64(rd32(b, off)) | u64(rd32(b, off + 4)) << 32}

MACH_HEADER :: 24 // mach_msg_header_t

@(test)
frames_messages_are_fixed_little_endian :: proc(t: ^testing.T) {
	buf: [256]u8
	// FRAME: gen u32, slot u32, seq u64, tick u64 after the header
	n := int(dh_frames_encode(4, 7, 2, 0x1122334455667788, 99, &buf[0]))
	testing.expect_value(t, n, MACH_HEADER + 24)
	testing.expect_value(t, rd32(buf[:], 20), 4) // msgh_id
	testing.expect_value(t, rd32(buf[:], 4), u32(n)) // msgh_size
	testing.expect_value(t, rd32(buf[:], MACH_HEADER), 7)
	testing.expect_value(t, rd32(buf[:], MACH_HEADER + 4), 2)
	testing.expect_value(t, rd64(buf[:], MACH_HEADER + 8), 0x1122334455667788)
	testing.expect_value(t, rd64(buf[:], MACH_HEADER + 16), 99)
	// RELEASE: gen, slot
	n = int(dh_frames_encode(5, 3, 1, 0, 0, &buf[0]))
	testing.expect_value(t, n, MACH_HEADER + 8)
	testing.expect_value(t, rd32(buf[:], 20), 5)
	testing.expect_value(t, rd32(buf[:], MACH_HEADER), 3)
	testing.expect_value(t, rd32(buf[:], MACH_HEADER + 4), 1)
	// RING_DONE: gen
	n = int(dh_frames_encode(3, 12, 0, 0, 0, &buf[0]))
	testing.expect_value(t, n, MACH_HEADER + 4)
	testing.expect_value(t, rd32(buf[:], MACH_HEADER), 12)
	// HELLO: key[32], tab_id u64
	n = int(dh_frames_encode(1, 0, 0, 42, 0, &buf[0]))
	testing.expect_value(t, n, MACH_HEADER + 32 + 8)
	testing.expect_value(t, rd64(buf[:], MACH_HEADER + 32), 42)
	// RING: header, body, 3 port descriptors (12 bytes each), gen count w h scale format
	testing.expect_value(t, int(dh_frames_encode(2, 0, 0, 0, 0, &buf[0])), MACH_HEADER + 4 + 3 * 12 + 6 * 4)
	testing.expect_value(t, int(dh_frames_encode(9, 0, 0, 0, 0, &buf[0])), 0) // no such message
}

@(test)
frames_key_and_sender_checks :: proc(t: ^testing.T) {
	a, b: [32]u8
	for i in 0 ..< 32 do a[i], b[i] = u8(i * 7), u8(i * 7)
	testing.expect_value(t, dh_frames_key_equal(&a[0], &b[0]), 1)
	b[31] ~= 1
	testing.expect_value(t, dh_frames_key_equal(&a[0], &b[0]), 0) // the last byte counts
	b[31] ~= 1
	b[0] ~= 0x80
	testing.expect_value(t, dh_frames_key_equal(&a[0], &b[0]), 0)
	// the tab's process group 500 and session 500 (Deckhand starts it with setsid)
	testing.expect_value(t, dh_frames_sender_in(500, 500, 500, 500), 1) // the child itself
	testing.expect_value(t, dh_frames_sender_in(612, 500, 500, 500), 1) // a grandchild in its own group, same session (sh -c "make run")
	testing.expect_value(t, dh_frames_sender_in(500, 77, 500, 500), 1) // left the session but not the group
	testing.expect_value(t, dh_frames_sender_in(612, 77, 500, 500), 0) // setsid: neither
	testing.expect_value(t, dh_frames_sender_in(-1, -1, 500, 500), 0) // a pid that is gone
	testing.expect_value(t, dh_frames_sender_in(0, 0, 0, 0), 0) // an unset channel never matches
}

@(test)
frames_only_current_frames_count :: proc(t: ^testing.T) {
	rel: u32 = 99
	// stale gen, no ring yet, bad slot: dropped
	testing.expect_value(t, dh_frames_on_frame(5, 0, 0, 4, 0, &rel), 0)
	testing.expect_value(t, dh_frames_on_frame(0, 0, 0, 0, 0, &rel), 0)
	testing.expect_value(t, dh_frames_on_frame(5, 0, 0, 5, 3, &rel), 0)
	// the first: taken
	testing.expect_value(t, dh_frames_on_frame(5, 0, 0, 5, 1, &rel), 1)
	testing.expect_value(t, rel, 99)
	// a newer one while slot 1 waits unshown: slot 1 goes back at once
	testing.expect_value(t, dh_frames_on_frame(5, 1, 1, 5, 2, &rel), 2)
	testing.expect_value(t, rel, 1)
	// the same slot again (never happens with a correct app): nothing to release twice
	rel = 99
	testing.expect_value(t, dh_frames_on_frame(5, 1, 2, 5, 2, &rel), 1)
	testing.expect_value(t, rel, 99)
}

@(test)
frames_ring_generations :: proc(t: ^testing.T) {
	r: Frame_Ring
	defer delete(r.gens)
	append(&r.gens, Ring_Gen{gen = 1, w = 800, h = 600, scale = 2})
	r.cur_gen = 1
	// frames of the current ring: each replaces the shown one, which retires
	_, _, retire := ring_take(&r, 1, 0, 1, 10)
	testing.expect(t, !retire, "the first frame retires nothing")
	og, os, retire2 := ring_take(&r, 1, 1, 2, 11)
	testing.expect(t, retire2 && og == 1 && os == 0, "the second frame retires slot 0")
	testing.expect_value(t, r.shown, 2)
	// a stale frame changes nothing
	_, _, retire3 := ring_take(&r, 7, 2, 3, 12)
	testing.expect(t, !retire3 && r.shown_slot == 1 && r.shown_seq == 2, "a stale gen is ignored")
	// a resize: gen 2 is current; gen 1 is shown until a gen-2 frame comes
	append(&r.gens, Ring_Gen{gen = 2, w = 1000, h = 600, scale = 2})
	r.cur_gen = 2
	free := make([dynamic]u32, context.temp_allocator)
	ring_freeable(&r, false, &free)
	testing.expect_value(t, len(free), 0) // not given back (RING_DONE) and on screen
	r.done_gen = 1
	ring_freeable(&r, false, &free)
	testing.expect_value(t, len(free), 0) // given back, but still on screen
	og, os, retire = ring_take(&r, 2, 0, 3, 13)
	testing.expect(t, retire && og == 1 && os == 1, "the first new-ring frame retires the old ring's slot")
	ring_freeable(&r, false, &free)
	testing.expect(t, len(free) == 1 && free[0] == 1, "now the old ring goes")
	// the app is gone: everything but the shown ring may go
	clear(&free)
	append(&r.gens, Ring_Gen{gen = 3, w = 1000, h = 600, scale = 2})
	ring_freeable(&r, true, &free)
	testing.expect(t, len(free) == 2 && free[0] == 1 && free[1] == 3, "app gone: all but the shown gen 2")
	// the restarted app's first frame replaces the dead one's kept slot: that ring goes too
	clear(&r.gens)
	append(&r.gens, Ring_Gen{gen = 2, w = 1000, h = 600, scale = 2, freed = true}, Ring_Gen{gen = 4, w = 1000, h = 600, scale = 2})
	r.cur_gen, r.done_gen = 4, 0
	clear(&free)
	ring_freeable(&r, false, &free)
	testing.expect_value(t, len(free), 0) // gen 2's last frame is still on screen
	ring_take(&r, 4, 0, 1, 1)
	ring_freeable(&r, false, &free)
	testing.expect(t, len(free) == 1 && free[0] == 2, "the kept slot goes once replaced")
}

@(test)
frames_resize_waits_for_the_size_to_settle :: proc(t: ^testing.T) {
	r: Frame_Ring
	defer delete(r.gens)
	t0 := time.tick_now()
	testing.expect(t, ring_wants_new(&r, 800, 600, 2, t0), "the first ring comes at once")
	append(&r.gens, Ring_Gen{gen = 1, w = 800, h = 600, scale = 2})
	r.cur_gen = 1
	testing.expect(t, !ring_wants_new(&r, 800, 600, 2, t0), "same size: no ring")
	t1 := time.tick_add(t0, 10 * time.Millisecond)
	testing.expect(t, !ring_wants_new(&r, 900, 600, 2, t1), "a drag: not yet")
	testing.expect(t, !ring_wants_new(&r, 900, 600, 2, time.tick_add(t1, 50 * time.Millisecond)), "still settling")
	testing.expect(t, !ring_wants_new(&r, 950, 600, 2, time.tick_add(t1, 80 * time.Millisecond)), "moved again: the wait starts over")
	testing.expect(t, ring_wants_new(&r, 950, 600, 2, time.tick_add(t1, 200 * time.Millisecond)), "settled: a new ring")
	testing.expect(t, ring_wants_new(&r, 800, 600, 1, time.tick_add(t1, 400 * time.Millisecond)) == false, "a DPI change is a size change: waits too")
	testing.expect(t, ring_wants_new(&r, 800, 600, 1, time.tick_add(t1, 600 * time.Millisecond)), "then a ring at the new scale")
}

@(test)
app_key_names_follow_sokol :: proc(t: ^testing.T) {
	testing.expect_value(t, app_key_name(.A), "a")
	testing.expect_value(t, app_key_name(.LEFT_SHIFT), "left_shift")
	testing.expect_value(t, app_key_name(._1), "1")
	testing.expect_value(t, app_key_name(.F6), "f6")
	testing.expect_value(t, app_key_name(.SPACE), "space")
	testing.expect_value(t, app_key_name(.INVALID), "") // unmapped: never sent as a key
}

@(test)
app_commands_parse_and_permissions :: proc(t: ^testing.T) {
	c, err := core.parse_command(`{"type":"new_app_tab","argv":["build/fake-app","--exit","75"],"title":"fake"}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	nt := c.(core.New_App_Tab)
	testing.expect(t, len(nt.argv) == 3 && nt.argv[2] == "75" && nt.title == "fake", "new_app_tab argv")
	c, err = core.parse_command(`{"type":"app_input","tab_id":4,"events":[{"event":"key","action":"down","key":"w"},{"event":"char","text":"é"}]}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	ai := c.(core.App_Input)
	testing.expect(t, len(ai.events) == 2 && ai.tab_id == 4, "app_input events")
	_, err = core.parse_command(`{"type":"app_input","tab_id":4,"events":["key w"]}`, context.temp_allocator)
	testing.expect(t, err != "", "events must be objects")
	c, err = core.parse_command(`{"type":"app_call","tab_id":4,"method":"tab.ping","timeout_ms":500}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	ac := c.(core.App_Call)
	testing.expect(t, ac.method == "tab.ping" && ac.timeout_ms == 500, "app_call's method")
	_, err = core.parse_command(`{"type":"app_call","tab_id":4}`, context.temp_allocator)
	testing.expect(t, err != "", "method is needed")
	// an app's program sends no commands, not even queries; the internal ones are Deckhand's
	testing.expect(t, !core.caller_may({kind = .App, tab_id = 4}, core.Get_State{}), "app: no queries")
	testing.expect(t, !core.caller_may({kind = .App, tab_id = 4}, core.New_App_Tab{}), "app: no commands")
	testing.expect(t, core.caller_may({kind = .Control}, core.App_Call{}), "control may call apps")
	// pi and Claude tabs (panel): their own session's app tabs only (app_apply checks the tab)
	testing.expect(t, core.caller_may({kind = .Panel, tab_id = 2}, core.App_Input{}), "pi tabs: their own session's app tabs")
	// and open, restart and close their own session's (app_apply checks the session: app_open_test.odin)
	testing.expect(t, core.caller_may({kind = .Panel, tab_id = 2}, core.New_App_Tab{}), "pi tabs: new app tabs in their own session")
	testing.expect(t, core.caller_may({kind = .Panel, tab_id = 2}, core.App_Restart{}), "pi tabs: their own session's restarts")
	testing.expect(t, core.caller_may({kind = .Panel, tab_id = 2}, core.App_Close{}), "pi tabs: their own session's app tabs closed")
	testing.expect(t, !core.caller_may({kind = .Script}, core.App_Update{}), "internal only")
	testing.expect(t, !core.caller_may({kind = .Control}, core.App_Call_Done{}), "internal only")
}

// An app's answer counts only for its own tab: another tab's reply with a
// guessed wire id leaves the request waiting.
@(test)
app_replies_only_from_the_asking_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // global maps outlive the test
	pending[strings.clone("a900")] = {tab_id = 7, type = strings.clone("tab.ping"), deadline = time.tick_add(time.tick_now(), time.Second)}
	defer app_fail_pending(7, "", "")
	app_apply(core.App_Call_Done{tab_id = 8, wire = "a900", ok = true, data = "{}"}, {kind = .Internal}, 0)
	testing.expect(t, "a900" in pending, "tab 8's reply to tab 7's request is ignored")
	app_apply(core.App_Call_Done{tab_id = 7, wire = "a900", ok = true, data = "{}"}, {kind = .Internal}, 0)
	testing.expect(t, !("a900" in pending), "tab 7's reply finishes it")
}

// app_events hands back what the app sent as one JSON value: trailing
// tokens on the app's line cannot add keys to the reply.
@(test)
app_events_cannot_be_injected :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // global maps outlive the test
	tab: u64 = 991
	defer core.app_events_forget(tab)
	core.app_event_in(tab, "tab.log", `{"type":"event","event":"tab.log","data":{"text":"hi"}}}],"next":999,"x":[{"y":{"z":0`)
	core.app_event_in(tab, "tab.log", `{"type":"event","event":"tab.log","data":{"text":"ok"}}`)
	out := core.app_events_json(tab, "log", 0, 10)
	v, err := json.parse_string(out, .JSON, true, context.temp_allocator)
	testing.expectf(t, err == nil, "%v: %s", err, out)
	obj := v.(json.Object)
	testing.expect_value(t, len(obj), 2) // events, next
	evs := obj["events"].(json.Array)
	testing.expect(t, len(evs) >= 1, "the clean event is there")
	last := evs[len(evs) - 1].(json.Object)
	testing.expect_value(t, obj["next"].(json.Integer), last["seq"].(json.Integer))
	for e in evs {
		inner := e.(json.Object)["event"].(json.Object)
		testing.expect(t, !("next" in inner) && !("x" in inner), "nothing of the trailing tokens")
	}
	// a single parse of the reply: no trailing tokens of its own
	testing.expect(t, strings.has_suffix(out, fmt.tprintf(`],"next":%d}`, last["seq"].(json.Integer))), out)
}

// An app's event topics are capped: a flood of new topic names is dropped.
@(test)
app_event_topics_are_capped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // global maps outlive the test
	tab: u64 = 992
	defer core.app_events_forget(tab)
	for i in 0 ..< core.APP_EVENT_TOPICS + 10 do core.app_event_in(tab, fmt.tprintf("tab.t%d", i), `{"type":"event","event":"x"}`)
	testing.expect_value(t, core.app_event_topic_count(tab), core.APP_EVENT_TOPICS)
}

// A stalled app whose ping timed out is pinged again APP_PING_AGAIN later:
// one late answer does not leave the tab "not responding" for good.
@(test)
app_stall_pings_again_after_a_timeout :: proc(t: ^testing.T) {
	t0 := time.tick_now()
	at :: proc(t0: time.Tick, ms: int) -> time.Tick {return time.tick_add(t0, time.Duration(ms) * time.Millisecond)}
	testing.expect(t, app_should_ping(false, false, {}, t0), "the first ping")
	// sent at t0; no answer within APP_PING_TIMEOUT (the wire is dropped)
	testing.expect(t, !app_should_ping(true, false, t0, at(t0, 500)), "one in flight")
	testing.expect_value(t, app_stall_status(.Stalled, false, false, t0, at(t0, 1500)), core.App_Status.Not_Responding)
	testing.expect(t, !app_should_ping(false, false, t0, at(t0, 2000)), "not before APP_PING_AGAIN")
	testing.expect(t, app_should_ping(false, false, t0, at(t0, 3500)), "again after a timeout")
	// the second ping (t1) is answered: stalled, no longer not responding
	t1 := at(t0, 3500)
	testing.expect_value(t, app_stall_status(.Not_Responding, true, false, t1, at(t1, 200)), core.App_Status.Not_Responding)
	testing.expect_value(t, app_stall_status(.Not_Responding, false, true, t1, at(t1, 300)), core.App_Status.Stalled)
	// answered pings repeat too
	testing.expect(t, app_should_ping(false, true, t1, at(t1, 3500)), "again after an answer")
}

@(test)
frames_hidden_release_spares_the_shown_slot :: proc(t: ^testing.T) {
	r := Frame_Ring{shown_gen = 3, shown_slot = 1}
	testing.expect(t, !ring_may_release_now(&r, 3, 1), "the shown slot stays")
	testing.expect(t, ring_may_release_now(&r, 3, 2), "another slot goes")
	testing.expect(t, ring_may_release_now(&r, 4, 1), "another ring's slot goes")
}

// app_events hands back the app's JSON as sent: tiny floats, integers past
// i64 and escaped control characters in keys survive (a re-marshal broke them).
@(test)
app_events_keep_the_apps_json :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // global maps outlive the test
	tab: u64 = 993
	defer core.app_events_forget(tab)
	line := `{"type":"event","event":"tab.log","data":{"f":1e-20,"n":12345678901234567890,"k\u0001":true}}`
	core.app_event_in(tab, "tab.log", line)
	out := core.app_events_json(tab, "log", 0, 10)
	testing.expectf(t, strings.contains(out, line), "the line as sent: %s", out)
	// still a single JSON value: no trailing tokens
	core.app_event_in(tab, "tab.log", `{"type":"event","event":"tab.log"} {"x":1}`)
	core.app_event_in(tab, "tab.log", `[1]`)
	testing.expect(t, strings.count(core.app_events_json(tab, "log", 0, 10), `"seq":`) == 1, "trailing tokens and non-objects refused")
}

_ :: sapp

// A browser tab's ring (local channel, in-process producer): the producer
// never gets the slot on screen nor one a drawn frame may still sample, an
// unshown frame's slot may be written again, RELEASE frees, close frees all.
// Real surfaces (8x8 px) on the default Metal device; no window.
@(test)
frames_local_ring_never_hands_out_a_held_slot :: proc(t: ^testing.T) {
	TAB :: u64(0x7E57_0000_0001)
	dev := dh_frames_device_for(0)
	testing.expect_value(t, dh_frames_local_open(TAB, dev), 1)
	defer dh_frames_chan_close(TAB)
	gen: u32
	slot: c.int
	tex, surf: rawptr
	acq :: proc(w: c.int, gen: ^u32, slot: ^c.int, tex, surf: ^rawptr) -> c.int {return dh_frames_local_acquire(TAB, w, 8, gen, slot, tex, surf)}
	testing.expect_value(t, acq(8, &gen, &slot, &tex, &surf), 0) // no ring yet: make one
	g := dh_frames_ring_new(TAB, 8, 8, 1)
	testing.expect(t, g != 0, "a ring")
	testing.expect_value(t, acq(9, &gen, &slot, &tex, &surf), 0) // larger: make one
	// frame 1 -> shown (polled and taken, as browser_frames_tick does)
	testing.expect_value(t, acq(8, &gen, &slot, &tex, &surf), 1)
	testing.expect(t, gen == g && tex != nil && surf != nil, "slot of the current ring")
	shown := slot
	testing.expect_value(t, dh_frames_local_frame(TAB, gen, slot, 1, 8, 8), 1)
	p: Frames_Poll
	dh_frames_poll(TAB, &p)
	testing.expect(t, p.has_frame == 1 && c.int(p.slot) == shown, "the frame is polled")
	testing.expect_value(t, dh_frames_local_slot_state(TAB, g, shown), FRAMES_SLOT_DECKHAND)
	// frames 2 and 3, never polled: neither gets the shown slot; 3 replaces 2 (freed at once)
	testing.expect_value(t, acq(8, &gen, &slot, &tex, &surf), 1)
	s2 := slot
	testing.expect(t, s2 != shown, "not the shown slot")
	dh_frames_local_frame(TAB, gen, s2, 2, 8, 8)
	testing.expect_value(t, acq(8, &gen, &slot, &tex, &surf), 1)
	s3 := slot
	testing.expect(t, s3 != shown && s3 != s2, "the free slot first")
	dh_frames_local_frame(TAB, gen, s3, 3, 8, 8)
	testing.expect_value(t, dh_frames_local_slot_state(TAB, g, s2), FRAMES_SLOT_FREE)
	// s2 is being written; the only other is s3, unshown: it is written again (its frame dropped)
	testing.expect_value(t, acq(8, &gen, &slot, &tex, &surf), 1)
	testing.expect_value(t, slot, s2)
	testing.expect_value(t, acq(8, &gen, &slot, &tex, &surf), 1)
	testing.expect_value(t, slot, s3)
	testing.expect_value(t, dh_frames_local_reclaimed(TAB), 1)
	// s2 and s3 written; s3 handed over and polled (now shown), the old shown one retired:
	dh_frames_local_unacquire(TAB, g, s2)
	dh_frames_local_frame(TAB, g, s3, 4, 8, 8)
	dh_frames_poll(TAB, &p)
	testing.expect(t, p.has_frame == 1 && c.int(p.slot) == s3, "frame 4 polled")
	testing.expect_value(t, acq(8, &gen, &slot, &tex, &surf), 1)
	testing.expect_value(t, slot, s2)
	// every slot held: the shown one (s3), the retired one whose GPU work may run
	// (old `shown`), and s2 being written. Nothing to give: drop.
	testing.expect_value(t, acq(8, &gen, &slot, &tex, &surf), -1)
	// RELEASE of the retired slot (after the GPU frame): it is free again
	dh_frames_release_now(TAB, g, u32(shown))
	dh_frames_peers() // the Mach queue's work is done (a barrier)
	testing.expect_value(t, dh_frames_local_slot_state(TAB, g, shown), FRAMES_SLOT_FREE)
	testing.expect_value(t, acq(8, &gen, &slot, &tex, &surf), 1)
	testing.expect_value(t, slot, shown)
	// a frame for an old ring is dropped and its slot freed
	g2 := dh_frames_ring_new(TAB, 8, 8, 1)
	// a smaller paint fits the ring (headroom): its size comes with the frame
	{
		g3: u32
		s3_: c.int
		t3, f3: rawptr
		testing.expect_value(t, dh_frames_local_acquire(TAB, 5, 3, &g3, &s3_, &t3, &f3), 1)
		testing.expect_value(t, dh_frames_local_frame(TAB, g3, s3_, 9, 5, 3), 1)
		dh_frames_poll(TAB, &p)
		testing.expect(t, p.has_frame == 1 && p.content_w == 5 && p.content_h == 3, "content size polled")
		testing.expect_value(t, dh_frames_local_acquire(TAB, 9, 3, &g3, &s3_, &t3, &f3), 0) // wider: a new ring
	}
	testing.expect_value(t, dh_frames_local_frame(TAB, g, slot, 5, 8, 8), 0)
	testing.expect_value(t, dh_frames_surface_count(TAB), 6)
	testing.expect(t, dh_frames_surface_bytes(TAB) > 0, "bytes counted")
	// an app's checks never count browser surfaces; closing frees them
	dh_frames_ring_free(TAB, g, -1)
	testing.expect_value(t, dh_frames_surface_count(TAB), 3)
	_ = g2
	testing.expect(t, dh_frames_local_chans() >= 1, "the channel counts while open")
	dh_frames_chan_close(TAB)
	testing.expect_value(t, dh_frames_surface_count(TAB), 0)
	testing.expect_value(t, dh_frames_surface_total_local(), 0)
	testing.expect_value(t, dh_frames_local_open(TAB + 1, dev) == 1 && dh_frames_surface_total() == 0, true)
	dh_frames_chan_close(TAB + 1)
	dh_frames_peers() // the Mach queue finished draining the closed channels
	testing.expect_value(t, dh_frames_local_chans(), 0)
}

// When a browser's ring is remade (browser.odin): only when a paint outgrows
// it (at most once per RING_SETTLE: a drag waits) or it is a grid step too
// big and the size settled. Sizes in px; RING_GRID 256.
@(test)
browser_ring_due_rules :: proc(t: ^testing.T) {
	t0 := time.tick_now()
	at :: proc(t0: time.Tick, ms: int) -> time.Tick {return time.tick_add(t0, time.Duration(ms) * time.Millisecond)}
	testing.expect_value(t, ring_grid_up(1), 256)
	testing.expect_value(t, ring_grid_up(256), 256)
	testing.expect_value(t, ring_grid_up(1560), 1792)
	// fits and the right size: never
	testing.expect(t, !browser_ring_due(1792, 1792, 1560, 1640, t0, t0, at(t0, 5000)), "fits")
	// within the grid step: never (a drag inside it makes no ring)
	testing.expect(t, !browser_ring_due(1792, 1792, 1600, 1700, at(t0, 4990), t0, at(t0, 5000)), "same grid cell")
	// outgrown: at once if no ring in the last RING_SETTLE, else wait
	testing.expect(t, browser_ring_due(1792, 1792, 1800, 1640, at(t0, 4990), t0, at(t0, 5000)), "outgrown")
	testing.expect(t, !browser_ring_due(1792, 1792, 1800, 1640, at(t0, 4990), at(t0, 4950), at(t0, 5000)), "outgrown, ring 50 ms ago")
	testing.expect(t, browser_ring_due(1792, 1792, 1800, 1640, at(t0, 4990), at(t0, 4890), at(t0, 5000)), "outgrown, ring 110 ms ago")
	// a grid step too big: only once the size stayed put
	testing.expect(t, !browser_ring_due(1792, 1792, 1200, 1640, at(t0, 4950), t0, at(t0, 5000)), "shrinking: not yet")
	testing.expect(t, browser_ring_due(1792, 1792, 1200, 1640, at(t0, 4850), t0, at(t0, 5000)), "shrunk and settled")
	testing.expect(t, !browser_ring_due(1792, 1792, 0, 0, t0, t0, at(t0, 5000)), "nothing painted")
}
