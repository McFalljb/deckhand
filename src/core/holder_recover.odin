package core

// The session holder lost mid-run (holder_lose: a send timed out, a rejoin failed, the holder
// died, #108). Until now nothing said so: the sessions it held could not be reached, and new tabs
// ran directly under the core (holder_wanted is false once lost), so they stop at its next restart
// or quit. The window now shows it (holder_lost_view: a bar over the centre, ui_holder.odin) with
// one way out, Holder_Recover (the bar's Restart session holder; this machine's user only):
//
//   - the old holder still runs: attach to it again, as a launch does (holder_client_start, every
//     peer, code and WELCOME check), and when it is the same holder run (its instance) the tabs
//     that waited for it (held away) get their terminals back from its tails (inexact, as after a
//     crash: holder_adopt_all), the same processes. What this core let go of meanwhile (a closed
//     tab) is released then. It does not answer: no second holder beside it; the bar then offers
//     to stop it, saying how many sessions that ends (stop: SIGTERM, then SIGKILL, only a process
//     that runs a session holder binary), and a new holder starts.
//   - it is gone (or stopped): a new holder starts. The tabs whose terminals were in it end here,
//     saying "the session holder stopped", and restart as usual.
//
// Either way new tabs are held again once a holder is attached.

import "core:fmt"
import "core:strings"
import "core:sync"

// What the window shows (Core_Live.holder_lost, or in process holder_lost_now).
Holder_Lost_Live :: struct {
	lost:     bool, // the holder this run used is lost: what it held can't be reached, new tabs aren't held
	alive:    bool, // its process still runs (so may its sessions)
	sessions: int, // its child processes, when alive (0 = not known)
	stop:     bool, // attaching to it again failed: the action stops it (its sessions end)
}

holder_lost_now :: proc() -> Holder_Lost_Live {
	if !state.settings.keep_sessions || !sync.atomic_load(&hc.lost) || hc.handed do return {}
	alive := holder_alive()
	return {lost = true, alive = alive, sessions = alive ? holder_children(hc.pid) : 0, stop = alive && hc.recover_failed}
}

// The core's (a replica's live section) or this process's.
holder_lost_view :: proc() -> Holder_Lost_Live {
	if replica_process do return state.live.holder_lost
	return holder_lost_now()
}

Holder_Recover :: struct {
	stop: bool, // the old holder still runs but did not answer: stop it first (its sessions end)
}

// Holder_Recover (main thread). See the top.
holder_recover :: proc(stop: bool) -> Result {
	if !sync.atomic_load(&hc.lost) || hc.handed do return fail("the session holder is not lost")
	for _, t in terms do if t.running && t.pty.held != 0 do return fail("the tabs of the lost session holder are still ending: try again in a moment")
	old_pid := hc.pid
	old_instance := strings.clone(hc.instance, context.temp_allocator)
	alive := holder_alive()
	if stop && alive {
		if exe := holder_pid_exe(old_pid); !strings.has_suffix(exe, "/" + HOLDER_BIN) do return fail("that process is not a session holder: nothing was stopped")
		log_ln("Deckhand: session holder: stopping the one that stopped answering (pid", old_pid, ") as the user asked; its sessions end")
		holder_stop_pid(old_pid)
		if hc.path != "" do sock_unlink(hc.path)
		alive = false
	}
	// the tabs whose process runs on in it (their terminal ids), and what this core let go of
	// meanwhile (every terminal that ended here: those minus the waiting ones)
	away := make(map[u64]u32, 8, context.temp_allocator)
	for s in state.open_sessions do for &tab in s.tabs do if id := tab_held_away(&tab); id != 0 do away[tab.id] = id
	released := make(map[u32]bool, 8, context.temp_allocator)
	sync.lock(&hc.mu)
	for id in hc.released do released[id] = true
	sync.unlock(&hc.mu)
	for _, id in away do delete_key(&released, id)
	if !alive do holder_away_end(away, "stopped")

	holder_client_reset()
	if !holder_client_start() {
		// as it was: lost (the held ids and the old instance are saved for the next launch)
		delete(hc.instance)
		hc.instance = strings.clone(old_instance)
		hc.pid = old_pid
		sync.atomic_store(&hc.lost, true)
		hc.recover_failed = alive
		window_state_changed()
		if alive do return fail("the session holder still isn't answering: no second one is started beside it")
		return fail("a new session holder did not start: new tabs still stop when Deckhand's core restarts")
	}
	// the old run still there (the same instance): its terminals go back to the tabs that waited.
	// Its pid now answering as another instance, or not running: that run is gone with its sessions.
	same := alive && hc.instance == old_instance
	gone := !pid_running(old_pid) || (hc.pid == old_pid && !same)
	if same {
		delete(held_holder)
		held_holder = strings.clone(hc.instance)
		for &s in state.open_sessions do for &tab in s.tabs do if id, has := away[tab.id]; has {
			tab.held, tab.held_away = id, 0
			tab.status = .Not_Started // adopt_tab takes its Term again
		}
	} else if gone && alive do holder_away_end(away, "stopped")
	holder_adopt_all(released)
	// a waiting tab whose terminal the holder no longer lists (it exited meanwhile): ended here
	n := 0
	for &s in state.open_sessions do for &tab in s.tabs do if _, has := away[tab.id]; has && same {
		if tab.status == .Running {
			n += 1
			continue
		}
		tab.status = .Exited
		if t := term_of(tab.id); t != nil do holder_term_ended(t, "it ended in the session holder")
		socket_forget_tab(tab.id)
	}
	log_fln("Deckhand: session holder: attached again (%s), %d session(s) back", same ? "the same run" : "a new one", n)
	if n > 0 do window_toast(fmt.tprintf("The session holder is back: %d session%s reconnected, and new tabs keep running again.", n, n == 1 ? "" : "s"))
	else do window_toast("A session holder runs again: tabs opened from now on keep running when Deckhand's core restarts.")
	window_state_changed()
	return {ok = true}
}

// The tabs that waited for a holder that is gone now: they end here, saying why, and restart as
// usual (their tokens go with their processes).
@(private = "file")
holder_away_end :: proc(away: map[u64]u32, why: string) {
	for &s in state.open_sessions do for &tab in s.tabs do if _, has := away[tab.id]; has {
		tab.held_away = 0
		if t := term_of(tab.id); t != nil do holder_term_ended(t, fmt.tprintf("the session holder %s", why))
		socket_forget_tab(tab.id)
	}
}

@(private = "file")
holder_term_ended :: proc(t: ^Term, what: string) {
	t.holder_away, t.holder_lost = 0, true
	msg := fmt.tprintf("\r\n\x1b[2m[%s: this session ended]\x1b[0m", what)
	term_vt_write(t, transmute([]u8)msg)
	t.changed = true
}
