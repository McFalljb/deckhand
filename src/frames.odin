package main

// An app tab's frame ring, Deckhand side (docs/ENGINE-BRIDGE.md §2): the
// bindings to src/native/frames_macos.m and the bookkeeping the frame loop
// does with them. The native side owns the Mach channel and the IOSurfaces;
// this file owns which ring generations are alive, which slot is on screen,
// the sokol images that sample them, and when an old ring may be freed.
//
// Per frame (app_tab.odin's app_frames_tick, before `if !app.redraw`):
// poll what arrived; a newer frame becomes the shown slot and the old one is
// retired (released after this frame's GPU work); a ring the app gave back
// (RING_DONE) and no longer on screen is freed. After sg.commit,
// dh_frames_committed posts the releases.
//
// Browser tabs use the same ring and rules through a local channel: CEF,
// in Deckhand's own process, is the producer (browser.odin; docs/BROWSER.md §1.1).

import "core:c"
import "core:encoding/hex"
import "core:time"

when ODIN_OS == .Darwin {
	foreign import pdframes {"../build/dh_frames.a", "system:Metal.framework", "system:IOSurface.framework", "system:Foundation.framework", "system:bsm"}

	Frames_Poll :: struct {
		flags:     u32,
		has_frame: c.int,
		gen, slot: u32,
		seq, tick: u64,
		recv_ms:   f64,
		cur_gen:   u32,
		done_gen:  u32,
		rx:        u64,
		replaced:  u64,
		stale:     u64,
		rejected:  u64,
		content_w: u32, // local channels: the frame's size in the slot (px)
		content_h: u32,
	}

	@(default_calling_convention = "c")
	foreign pdframes {
		dh_frames_serve_start :: proc(mtl_device: rawptr) -> c.int ---
		dh_frames_service :: proc() -> cstring ---
		dh_frames_device_id :: proc() -> u64 ---
		dh_frames_qlimit :: proc() -> c.int ---
		dh_frames_take_wake :: proc() -> c.int ---
		dh_frames_chan_open :: proc(tab_id: u64, key: [^]u8, pgid, sid: c.int) -> c.int ---
		dh_frames_chan_set_proc :: proc(tab_id: u64, pgid, sid: c.int) ---
		dh_frames_chan_key :: proc(tab_id: u64, out: [^]u8) -> c.int ---
		dh_frames_chan_stop :: proc(tab_id: u64) ---
		dh_frames_chan_close :: proc(tab_id: u64) ---
		dh_frames_ring_new :: proc(tab_id: u64, w, h: c.int, scale: f32) -> u32 ---
		dh_frames_ring_free :: proc(tab_id: u64, gen: u32, keep_slot: c.int) ---
		dh_frames_slot_texture :: proc(tab_id: u64, gen: u32, slot: c.int) -> rawptr ---
		dh_frames_poll :: proc(tab_id: u64, out: ^Frames_Poll) -> c.int ---
		dh_frames_release_now :: proc(tab_id: u64, gen, slot: u32) ---
		dh_frames_retire :: proc(tab_id: u64, gen, slot: u32) ---
		dh_frames_shown :: proc(tab_id: u64, recv_ms: f64) ---
		dh_frames_committed :: proc(mtl_queue: rawptr) ---
		dh_frames_latency :: proc(tab_id: u64, out: [^]f64, cap: c.int) -> c.int ---
		dh_frames_pixel :: proc(tab_id: u64, gen: u32, slot: c.int, x, y: c.int, rgb: ^u32) -> c.int ---
		dh_frames_read :: proc(tab_id: u64, gen: u32, slot: c.int, x, y, w, h: c.int, dst: [^]u8) -> c.int ---
		dh_frames_surface_count :: proc(tab_id: u64) -> c.int ---
		dh_frames_surface_total :: proc() -> c.int ---
		dh_frames_peers :: proc() -> c.int ---
		// local channels (browser tabs: the producer is CEF, in process; browser.odin)
		dh_frames_local_open :: proc(tab_id: u64, mtl_device: rawptr) -> c.int ---
		dh_frames_local_acquire :: proc(tab_id: u64, w, h: c.int, gen: ^u32, slot: ^c.int, texture: ^rawptr, surface: ^rawptr) -> c.int --- // (the producer, cef_macos.m; tests)
		dh_frames_local_unacquire :: proc(tab_id: u64, gen: u32, slot: c.int) ---
		dh_frames_local_frame :: proc(tab_id: u64, gen: u32, slot: c.int, seq: u64, w, h: c.int) -> c.int ---
		dh_frames_device_for :: proc(registry_id: u64) -> rawptr --- // (tests: the default device, retained)
		dh_frames_local_slot_state :: proc(tab_id: u64, gen: u32, slot: c.int) -> c.int ---
		dh_frames_local_reclaimed :: proc(tab_id: u64) -> u64 ---
		dh_frames_surface_total_local :: proc() -> c.int ---
		dh_frames_surface_bytes :: proc(tab_id: u64) -> u64 ---
		dh_frames_local_chans :: proc() -> c.int --- // local channels used or still draining (tests)
		// test mode: writes into textures GPU frames not completed yet sample (browser.odin)
		dh_frames_test_track :: proc(on: c.int, lag_ms: c.int) ---
		dh_frames_sampled :: proc(tex: rawptr) ---
		dh_frames_inflight_writes :: proc() -> u64 ---
		// pure rules (frames_test.odin)
		dh_frames_key_equal :: proc(a, b: [^]u8) -> c.int ---
		dh_frames_sender_in :: proc(sender_pgid, sender_sid, pgid, sid: c.int) -> c.int ---
		dh_frames_on_frame :: proc(cur_gen: u32, has_latest: c.int, latest_slot, gen, slot: u32, release_slot: ^u32) -> c.int ---
		dh_frames_encode :: proc(id: c.int, a, b: u32, c_, d: u64, buf: [^]u8) -> c.int ---
	}
}

FRAMES_F_CONNECTED :: 1
FRAMES_F_DEAD :: 2
FRAMES_F_STALLED :: 4
FRAMES_F_REJECTED :: 8
// a local channel's slot (dh_frames_local_slot_state)
FRAMES_SLOT_FREE :: 0
FRAMES_SLOT_WRITING :: 1
FRAMES_SLOT_DECKHAND :: 2
FRAME_SLOTS :: 3
RING_SETTLE :: 100 * time.Millisecond // a new ring once the pane's size stayed this long

Ring_Gen :: struct {
	gen:   u32,
	w, h:  int, // px
	scale: f32,
	// the window's sokol image and view sampling each slot (app_tab.odin, browser.odin), by id
	// (sg.Image{id}, sg.View{id}; 0 = none): the record holds no sokol types
	image: [FRAME_SLOTS]u32,
	view:  [FRAME_SLOTS]u32,
	freed: bool, // surfaces gone (all but the shown slot of a dead app's ring)
}

Frame_Ring :: struct {
	gens:       [dynamic]Ring_Gen, // alive generations, oldest first
	cur_gen:    u32, // the ring the app renders into now (0 = none yet)
	shown_gen:  u32, // 0 = nothing on screen yet
	shown_slot: int,
	shown_seq:  u64,
	shown_tick: u64,
	shown:      u64, // frames that became the shown one
	done_gen:   u32, // highest gen the app gave back
	want_w:     int, // the pane's size (px) when it last changed, and when
	want_h:     int,
	want_since: time.Tick,
	last_frame: time.Tick, // the last FRAME taken (stall detection)
}

// A frame arrived for the ring the app uses now: it becomes the shown one.
// Returns the slot it replaced on screen (retire it: released after this
// frame's GPU work), if any. Pure bookkeeping.
ring_take :: proc(r: ^Frame_Ring, gen, slot: u32, seq, tick: u64) -> (old_gen: u32, old_slot: int, retire: bool) {
	if gen == 0 || gen != r.cur_gen || int(slot) >= FRAME_SLOTS do return
	if r.shown_gen != 0 && !(r.shown_gen == gen && r.shown_slot == int(slot)) {
		old_gen, old_slot, retire = r.shown_gen, r.shown_slot, true
	}
	r.shown_gen, r.shown_slot, r.shown_seq, r.shown_tick = gen, int(slot), seq, tick
	r.shown += 1
	return
}

// The generations that may be freed now: not on screen, and older than the
// current one and given back by the app (RING_DONE), or the app is gone, or
// already freed but for the slot that was on screen (a dead app's last frame,
// replaced by its restart's). Pure.
ring_freeable :: proc(r: ^Frame_Ring, app_gone: bool, out: ^[dynamic]u32) {
	for g in r.gens {
		if g.gen == r.shown_gen do continue
		if g.gen == r.cur_gen && !app_gone do continue
		if app_gone || g.freed || g.gen <= r.done_gen do append(out, g.gen)
	}
}

// Whether the pane size calls for a new ring: it differs from the current
// ring's and has stayed the same for RING_SETTLE (a drag shows the old frame
// clipped meanwhile). Pure but for the clock passed in.
ring_wants_new :: proc(r: ^Frame_Ring, w, h: int, scale: f32, now: time.Tick) -> bool {
	if w <= 0 || h <= 0 do return false
	if w != r.want_w || h != r.want_h {
		r.want_w, r.want_h, r.want_since = w, h, now
		return r.cur_gen == 0 // the first ring: at once
	}
	if r.cur_gen == 0 do return true
	cur := ring_gen(r, r.cur_gen)
	if cur != nil && cur.w == w && cur.h == h && cur.scale == scale do return false
	return time.tick_diff(r.want_since, now) >= RING_SETTLE
}

// ---- the display link's rate (power; main.odin, src/native/platform_macos.m) ----
//
// Deckhand's frame loop runs at the window's screen's maximum only while a tab on screen shows
// live frames: an app tab connected, or an app or browser tab that framed in the last
// DISPLAY_FAST_HOLD. Otherwise at most DISPLAY_IDLE_FPS (a 120 Hz MacBook's rate, as before):
// terminals and the chrome gain nothing from 240 wake-ups a second. Apps are always told the
// screen's real maximum (tab.display).
DISPLAY_FAST_HOLD :: time.Second
DISPLAY_IDLE_FPS :: 120

// The cap on the display link for this frame: 0 = none (the screen's maximum). Pure.
display_link_cap :: proc(live: bool) -> int {return live ? 0 : DISPLAY_IDLE_FPS}

// A tab keeps the display link fast: on screen, and an app connected or frames arriving. Pure.
display_tab_live :: proc(visible, connected, framed: bool) -> bool {return visible && (connected || framed)}

// A frame was taken within DISPLAY_FAST_HOLD of now. Pure but for the clock passed in.
ring_framed_recently :: proc(r: ^Frame_Ring, now: time.Tick) -> bool {
	return r.last_frame != {} && time.tick_diff(r.last_frame, now) <= DISPLAY_FAST_HOLD
}

ring_gen :: proc(r: ^Frame_Ring, gen: u32) -> ^Ring_Gen {
	for &g in r.gens do if g.gen == gen do return &g
	return nil
}

// A hidden tab's frame goes back at once, unless it names the slot on show
// (an app that sends a slot again must not get the one Deckhand samples).
ring_may_release_now :: proc(r: ^Frame_Ring, gen: u32, slot: u32) -> bool {
	return !(r.shown_gen == gen && r.shown_slot == int(slot))
}

// What an app tab's hello says of its frame channel (the core writes it from the window's facts,
// client.odin): the service and the GPU's id ("" = none), and the tab's channel key (hex; ok false:
// no channel). The key is never logged.
frames_service :: proc() -> (service: string, device: u64) {
	when ODIN_OS == .Darwin {
		return string(dh_frames_service()), dh_frames_device_id()
	}
	return "", 0
}

frames_chan_key :: proc(tab_id: u64) -> (key_hex: string, ok: bool) {
	when ODIN_OS == .Darwin {
		key: [32]u8
		if dh_frames_chan_key(tab_id, &key[0]) == 1 do return string(hex.encode(key[:], context.temp_allocator)), true
	}
	return "", false
}

// BGRA pixels of a region of an app tab's frame slot (ui_comments.odin's crops); false: none.
frames_read :: proc(tab_id: u64, gen: u32, slot: int, x, y, w, h: int, dst: []u8) -> bool {
	when ODIN_OS == .Darwin {
		return dh_frames_read(tab_id, gen, c.int(slot), c.int(x), c.int(y), c.int(w), c.int(h), raw_data(dst)) != 0
	}
	return false
}
