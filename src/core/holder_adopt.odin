package core

// Quit and launch with the session holder (docs/plans/background-core.md §7.2, §7.7):
//
//   holder_handover()   at quit, keep_sessions on: GOODBYE{handover}, every held terminal fed
//                       up to its acked offset and snapshotted there into
//                       <data>/handover/<term>.snap, listed (with each file's sha256) in the
//                       MAC'd <data>/handover.json. The processes run on in the holder.
//   holder_adopt_all()  at launch, after persist_load: every restored tab whose saved "held"
//                       the holder still lists gets its terminal now, from the snapshot when
//                       handover.json verifies and is this holder's, then the holder's tail;
//                       otherwise from the tail alone (inexact). Terminals no tab claims are
//                       released: invisible sessions are worse than ended ones.
//
// Reading fails closed at every step: the MAC first (macfile_read), the body's shape, every
// entry, then each snapshot file's size and sha256 against the MAC'd list, and only then
// snapshot_decode (GHOSTSNP declares its own history sizes).

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import gh "../ghostty"
import jg "../jsonguard"
import "../trust"

HANDOVER_KIND :: "handover"
HANDOVER_FILE :: "handover.json"
HANDOVER_DIR :: "handover"
HANDOVER_READER :: 1 // the newest handover.json format this build reads (its min_reader floor)
HANDOVER_SNAP_MAX :: 256 * 1024 * 1024 // one snapshot file (20 MiB scrollback, compressed: far less)

// workspace.json's "holder": the instance of the holder its held ids were saved with
// (persist.odin); adopt uses them only with that same holder.
held_holder: string

Handover_Term :: struct {
	term:    i64,
	offset:  u64,
	sha256:  string, // of <term>.snap
	format:  string,
	inexact: bool,
}

Handover_File :: struct {
	v:          i64,
	min_reader: i64,
	holder:     string, // WELCOME.instance of the holder it was written for
	written:    i64, // unix seconds
	terminals:  []Handover_Term,
}

// The body of a verified handover.json, checked: a JSON object of sane shape, at most
// HOLDER_MAX_TERMS entries, each with a terminal id in 1..max u32 (unique) and a 64-hex sha256.
// Any bad entry refuses the whole file. Pure (holder_adopt_test.odin); temp allocator.
HANDOVER_MAX_DEPTH :: 8 // the file nests 3 deep (root, terminals, an entry)
handover_parse :: proc(body: string) -> (f: Handover_File, ok: bool, why: string) {
	if !json_shape_ok(body, 8 * HOLDER_MAX_TERMS + 64) do return {}, false, "shape"
	// jg after the MAC (handover_load) and the item count: 3 levels deep when written
	v, perr := jg.parse_string(body, .JSON, true, context.temp_allocator, max_depth = HANDOVER_MAX_DEPTH)
	if perr != nil do return {}, false, "not JSON"
	root, is := v.(json.Object)
	if !is do return {}, false, "not an object"
	// the types first: unmarshal would take "3" for 3
	for k in ([]string{"v", "min_reader", "written"}) do if x, has := root[k]; has {
		if _, n := x.(json.Integer); !n do return {}, false, "wrong types"
	}
	if x, has := root["holder"]; has {
		if _, str := x.(json.String); !str do return {}, false, "wrong types"
	}
	if x, has := root["terminals"]; has {
		arr, isa := x.(json.Array)
		if !isa do return {}, false, "wrong types"
		for e in arr {
			o, iso := e.(json.Object)
			if !iso do return {}, false, "wrong types"
			_, ti := o["term"].(json.Integer)
			_, oi := o["offset"].(json.Integer)
			_, hs := o["sha256"].(json.String)
			if !ti || !oi || !hs || o["offset"].(json.Integer) < 0 do return {}, false, "wrong types"
		}
	}
	if jg.unmarshal_string(body, &f, .JSON, context.temp_allocator, max_depth = HANDOVER_MAX_DEPTH) != nil do return {}, false, "wrong types"
	if len(f.terminals) > HOLDER_MAX_TERMS do return {}, false, "too many terminals"
	seen := make(map[i64]bool, len(f.terminals), context.temp_allocator)
	for t in f.terminals {
		if t.term <= 0 || t.term > i64(max(u32)) do return {}, false, "a terminal id out of range"
		if seen[t.term] do return {}, false, "a terminal listed twice"
		seen[t.term] = true
		if len(t.sha256) != 64 do return {}, false, "a bad sha256"
		if _, hok := hex.decode(transmute([]u8)t.sha256, context.temp_allocator); !hok do return {}, false, "a bad sha256"
	}
	return f, true, ""
}

@(private = "file")
data_path :: proc(name: string) -> string {return fmt.tprintf("%s/%s", strings.trim_right(home_root, "/"), name)}

@(private = "file")
snap_path :: proc(term: u32) -> string {return fmt.tprintf("%s/%s/%d.snap", strings.trim_right(home_root, "/"), HANDOVER_DIR, term)}

// <data>/handover: a real 0700 directory of ours (made if missing). "" = fine, else why not.
@(private = "file")
handover_dir_ready :: proc() -> string {
	dir := data_path(HANDOVER_DIR)
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	posix.mkdir(cdir, posix.S_IRWXU)
	st: posix.stat_t
	if posix.lstat(cdir, &st) != .OK do return "cannot make it"
	if !posix.S_ISDIR(st.st_mode) || st.st_uid != posix.getuid() do return "not a directory of ours"
	if st.st_mode & (posix.S_IRWXG | posix.S_IRWXO) != {} && posix.chmod(cdir, posix.S_IRWXU) != .OK do return "cannot make it private"
	return ""
}

// Writes bytes to path: a 0600 temp file beside it (O_EXCL, O_NOFOLLOW), fsync, rename.
@(private = "file")
file_write_private :: proc(path: string, bytes: []u8) -> bool {
	tmp := fmt.tprintf("%s.tmp-%d", path, posix.getpid())
	ctmp := strings.clone_to_cstring(tmp, context.temp_allocator)
	posix.unlink(ctmp)
	fd := posix.open(ctmp, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 do return false
	rest := bytes
	for len(rest) > 0 {
		n := posix.write(fd, raw_data(rest), len(rest))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 {
			posix.close(fd)
			posix.unlink(ctmp)
			return false
		}
		rest = rest[n:]
	}
	ok := posix.fsync(fd) == .OK
	posix.close(fd)
	if ok do ok = posix.rename(ctmp, strings.clone_to_cstring(path, context.temp_allocator)) == 0
	if !ok do posix.unlink(ctmp)
	return ok
}

// A regular file (not a link) of at most max bytes, or ok = false. Temp allocator.
@(private = "file")
file_read_capped :: proc(path: string, max_n: int) -> (b: []u8, ok: bool) {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NOFOLLOW, .CLOEXEC, .NONBLOCK})
	if fd < 0 do return nil, false
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) || st.st_uid != posix.getuid() || st.st_size < 0 || i64(st.st_size) > i64(max_n) do return nil, false
	b = make([]u8, int(st.st_size), context.temp_allocator)
	got := 0
	for got < len(b) {
		n := posix.read(fd, &b[got], uint(len(b)) - uint(got))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do return nil, false
		got += int(n)
	}
	return b, true
}

// Removes handover.json and every <n>.snap in <data>/handover (read once, then gone).
@(private = "file")
handover_clear :: proc() {
	os.remove(data_path(HANDOVER_FILE))
	files, err := os.read_all_directory_by_path(data_path(HANDOVER_DIR), context.temp_allocator)
	if err != nil do return
	for f in files {
		if !strings.has_suffix(f.name, ".snap") do continue
		if _, nok := strconv.parse_u64(strings.trim_suffix(f.name, ".snap"), 10); nok do os.remove(f.fullpath)
	}
}

// ---- quit ----

// At quit with keep_sessions on: true once the holder keeps the sessions; the tabs are then
// left running (close_all sends no RELEASE). False: nothing is kept (no holder, the setting
// off, no held tab), so quit as without a holder. When the data dir can't be written (§7.7
// "disk full: abort before GOODBYE", sessions kept) no GOODBYE goes out and nothing else
// either: the holder sees a crash and the next launch restores from its tails, inexact. A
// failure after the GOODBYE (a snapshot or handover.json that cannot be written) ends the same.
holder_handover :: proc() -> bool {
	if !hc.on || hc.lost || hc.handed || !state.settings.keep_sessions do return false
	held := make([dynamic]^Term, context.temp_allocator)
	for _, t in terms do if t.running && t.pty.held != 0 do append(&held, t)
	if len(held) == 0 do return false
	if why := handover_dir_ready(); why != "" {
		fmt.eprintln("Deckhand: session holder: no handover (the handover folder:", why, "): the sessions run on, restored from the holder's tails next launch")
		holder_leave()
		return true
	}
	probe := data_path(HANDOVER_DIR + "/probe")
	if !file_write_private(probe, transmute([]u8)string("ok")) {
		fmt.eprintln("Deckhand: session holder: no handover (cannot write the data dir): the sessions run on, restored from the holder's tails next launch")
		holder_leave()
		return true
	}
	os.remove(probe)
	handover_clear()
	hc.handover = true
	feed :: proc(d: rawptr) {for t in (^[dynamic]^Term)(d)^ do handover_feed(t)}
	// an update names its successor (holder_successor.odin): the ack's secret goes to the relaunch
	// helper, and the holder then waits for that app alone (at most a minute)
	successor := relaunch_helper_waiting() || core_handover_due()
	if !holder_goodbye("handover", feed, &held, successor) do return true // lost or left: whatever the holder kept, the next launch finds (the helper gets no secret)
	// the holder sends every OUTPUT before the ack and nothing after it
	deadline := time.tick_add(time.tick_now(), HOLDER_WAIT)
	for {
		for t in held do handover_feed(t) // keeps the reader thread under its backlog cap
		sync.lock(&hc.mu)
		done := hc.acked || hc.lost
		if !done do sync.cond_wait_with_timeout(&hc.cond, &hc.mu, 10 * time.Millisecond)
		sync.unlock(&hc.mu)
		if done || time.tick_diff(time.tick_now(), deadline) <= 0 do break
	}
	if !hc.acked {
		fmt.eprintln("Deckhand: session holder: no GOODBYE_ACK; the next launch restores from the tails")
		return true
	}
	if successor && relaunch_helper_waiting() { // a core's handover keeps it for its successor (core_handover_finish)
		sync.lock(&hc.mu)
		secret := string(hc.successor[:hc.successor_len])
		relaunch_helper_send(secret) // at once: a later failure here still leaves the holder to it
		for &b in hc.successor do b = 0
		hc.successor_len = 0
		sync.unlock(&hc.mu)
	}
	file := Handover_File{v = 1, min_reader = 1, holder = hc.instance, written = time.now()._nsec / 1e9}
	list := make([dynamic]Handover_Term, context.temp_allocator)
	for t in held {
		handover_feed(t)
		id := t.pty.held
		sync.lock(&hc.mu)
		off, acked := hc.ack[id]
		h := hc.held[id]
		gap := h == nil || h.gap || h.next != off
		sync.unlock(&hc.mu)
		if !acked do continue
		meta := Snapshot_Meta{offset = off, xpixel = i64(min(f32(t.cols) * t.cell.x, 65535)), ypixel = i64(min(f32(t.rows) * t.cell.y, 65535))}
		blob, used, err := snapshot_encode(t.gt, meta, core_handover_formats(), fallback_ok = true, allocator = context.temp_allocator)
		if err != .None || !file_write_private(snap_path(id), blob) {
			fmt.eprintln("Deckhand: session holder: no snapshot of terminal", id, err)
			continue
		}
		sum := token_hash(string(blob))
		append(&list, Handover_Term{term = i64(id), offset = off, sha256 = string(hex.encode(sum[:], context.temp_allocator)), format = used.format, inexact = used.inexact || gap || t.inexact})
		if autotest_active {
			hsh, _ := screen_hash(t.gt)
			fmt.printfln("[autotest] handover %d offset %d hash %x", id, off, hsh)
		}
	}
	file.terminals = list[:]
	body, _ := json.marshal(file, {}, context.temp_allocator)
	if ok, why := macfile_write(data_path(HANDOVER_FILE), HANDOVER_KIND, string(body), hc.key[:]); !ok {
		fmt.eprintln("Deckhand: session holder: cannot write handover.json:", why)
		handover_clear()
	}
	sock_shutdown(hc.fd) // done: the holder lingers until we close (src/holder: LINGER)
	return true
}

// Everything received for a held terminal into it, unbudgeted (its exit, if any, is left for
// the next launch: the holder lists it).
@(private = "file")
handover_feed :: proc(t: ^Term) {
	holder_pull(t.pty.held, &t.reader)
	sync.lock(&t.reader.mu)
	if n := len(t.reader.inbox); n > 0 {
		term_vt_write(t, t.reader.inbox[:n])
		clear(&t.reader.inbox)
	}
	sync.unlock(&t.reader.mu)
}

// ---- launch ----

Handover_Snap :: struct {
	offset:  u64,
	blob:    []u8, // temp; its sha256 matched the MAC'd list
	inexact: bool,
}

// The snapshots of a handover.json that verifies and is this holder's (§7.7), by terminal;
// empty otherwise. The files are removed either way. Temp allocator.
@(private = "file")
handover_take :: proc() -> map[u32]Handover_Snap {
	out := make(map[u32]Handover_Snap, 16, context.temp_allocator)
	defer handover_clear()
	body, ok, why := macfile_read(data_path(HANDOVER_FILE), HANDOVER_KIND, hc.key[:], context.temp_allocator)
	if !ok {
		if why != "missing" do fmt.eprintln("Deckhand: handover.json not used:", why)
		return out
	}
	f, pok, pwhy := handover_parse(body)
	if !pok {
		fmt.eprintln("Deckhand: handover.json not used:", pwhy)
		return out
	}
	if d := trust.handover_fresh(f.min_reader, HANDOVER_READER, f.holder, hc.instance, hc.previous); d != .Use {
		fmt.eprintln("Deckhand: handover.json not used:", d)
		return out
	}
	for t in f.terminals {
		blob, rok := file_read_capped(snap_path(u32(t.term)), HANDOVER_SNAP_MAX)
		if !rok do continue
		sum := token_hash(string(blob))
		if string(hex.encode(sum[:], context.temp_allocator)) != t.sha256 {
			fmt.eprintln("Deckhand: handover: the snapshot of terminal", t.term, "does not match handover.json: not used")
			continue
		}
		out[u32(t.term)] = {offset = t.offset, blob = blob, inexact = t.inexact}
	}
	return out
}

// At launch, after the workspace is restored: the held tabs get their terminals (see the top).
// Every tab's saved held id is cleared, adopted or not.
holder_adopt_all :: proc() {
	defer hc.adopt_done = true
	any_held := false
	for s in state.open_sessions do for t in s.tabs do if t.held != 0 do any_held = true
	started := holder_client_start()
	if !started {
		// a holder answered but did not attach: what it kept runs on there, so those tabs wait
		// (not started, held ids saved again) rather than start a second copy beside it
		for &s in state.open_sessions do for &t in s.tabs {
			if hc.unreachable && t.held != 0 && t.status == .Not_Started do t.held_away = t.held
			t.held = 0
		}
		return
	}
	// the held ids are this holder's only if saved with it (two holders both number from 1)
	same := held_holder != "" && held_holder == hc.instance
	if any_held && !same do fmt.eprintln("Deckhand: session holder: workspace.json's held ids are another holder's: not adopted")
	listed := make(map[u32]bool, 16, context.temp_allocator)
	for &s in state.open_sessions do for &t in s.tabs do if t.held != 0 {
		listed[t.held] = true
		if !same do t.held = 0 // restored as without a holder
	}
	if !hc.tokens_loaded && any_held && hc.tokens_why != "missing" do fmt.eprintln("Deckhand: tokens.json not used:", hc.tokens_why) // enabled at attach (holder_connect)
	snaps := handover_take()
	untrusted := 0
	for &s in state.open_sessions do for &tab in s.tabs {
		id := tab.held
		tab.held = 0
		if id == 0 || tab.status != .Not_Started do continue
		kind: Held_Kind
		switch _ in tab.kind {
		case Shell_Tab:  kind = .Shell
		case Pi_Tab:     kind = .Pi
		case Claude_Tab: kind = .Claude
		case Editor_Tab, Changes_Tab, Markdown_Tab, Browser_Tab, App_Tab:
			continue
		}
		// what the terminal was started as (the MAC'd tokens.json): never into another kind of
		// tab (workspace.json is not MAC'd: an edit could put a Claude's id on a shell tab)
		saved, known := socket_tokens_start_of(id)
		if hc.tokens_loaded && (!known || saved.kind != kind) {
			fmt.eprintln("Deckhand: session holder: terminal", id, "was not started as this", HELD_KIND_NAMES[kind], "tab (tokens.json): not adopted")
			continue
		}
		if !adopt_tab(&s, &tab, id, snaps, saved, known) do continue
		start := Held_Start{kind = kind}
		if pk, is_pi := tab.kind.(Pi_Tab); is_pi do start.pi_ro, start.extras = pk.readonly, tab.reload.extras
		if !socket_tokens_adopt(id, tab.id, start) && kind != .Shell do untrusted += 1
		ct, is_cl := &tab.kind.(Claude_Tab)
		if is_cl {
			if t := term_of(tab.id); t != nil do socket_claude_pid(tab.id, t.pty.pid) // its hellos come from below it
		}
		// a read-only Claude without trusted ack state is stopped (docs/CLAUDE.md §1a); so is
		// anything whose saved state says it needs the read-only guard, whatever its tab
		ro, found := socket_tokens_ro_of(id)
		if ((found && ro.need) || (is_cl && ct.readonly)) && !claude_adopt_ro_ok(id) {
			if is_cl do claude_adopt_ro_stop(tab.id)
			else if t := term_of(tab.id); t != nil {
				socket_forget_tab(tab.id)
				term_note(t, CLAUDE_GUARD_UNTRUSTED)
				pty_kill_group(&t.pty, i32(posix.Signal.SIGKILL))
			}
		}
	}
	// entries for terminals the holder no longer lists: an id can come back for a new one
	welcomed := make([dynamic]u32, context.temp_allocator)
	sync.lock(&hc.mu)
	for id, h in hc.held do if h.welcomed do append(&welcomed, id)
	sync.unlock(&hc.mu)
	socket_tokens_prune(welcomed[:])
	note := untrusted > 0 ? fmt.tprintf("%d session%s kept running but can't reach Deckhand: restart %s to reconnect.", untrusted, untrusted == 1 ? "" : "s", untrusted == 1 ? "it" : "them") : ""
	// terminals no restored tab claimed: hung up only when nothing can be lost, else kept unseen
	gone := make([dynamic]u32, context.temp_allocator)
	kept := 0
	sync.lock(&hc.mu)
	for id, h in hc.held do if h.welcomed && !h.claimed {
		if held_release_unclaimed(h.eof && h.exit.known, persist.restored_clean, same, listed[id]) {
			append(&gone, id)
		} else {
			h.kept, h.tail_len = true, 0
			clear(&h.buf)
			kept += 1
		}
	}
	sync.unlock(&hc.mu)
	for id in gone {
		fmt.eprintln("Deckhand: session holder: releasing terminal", id, "(no tab claims it)")
		socket_tokens_release(id)
		holder_release(id)
	}
	if kept > 0 {
		fmt.eprintln("Deckhand: session holder:", kept, "terminal(s) no restored tab claims: kept running")
		note = strings.concatenate({holder_kept_text(kept), note == "" ? "" : " ", note}, context.temp_allocator)
	}
	if note != "" do window_toast(note, err = true)
}

// Adopts holder terminal id into tab (its Term made now); saved: what tokens.json says it was
// started as, when known. False: not adoptable (gone, already claimed, listed with a bad size).
@(private = "file")
adopt_tab :: proc(s: ^Open_Session, tab: ^Tab, id: u32, snaps: map[u32]Handover_Snap, saved: Held_Start, known: bool) -> bool {
	sync.lock(&hc.mu)
	h := hc.held[id]
	if h == nil || !h.welcomed || h.claimed || h.lost {
		sync.unlock(&hc.mu)
		return false
	}
	h.claimed = true
	// the TAIL (at the front of buf); what came after it stays for term_pump
	tail := make([]u8, h.tail_len, context.temp_allocator)
	copy(tail, h.buf[:h.tail_len])
	remove_range(&h.buf, 0, h.tail_len)
	tail_start := h.tail_start
	tail_end := tail_start + u64(len(tail))
	pid, cols, rows := h.pid, h.cols, h.rows
	h.tail_len = 0
	sync.unlock(&hc.mu)

	t := new_term(tab.id)
	exact := false
	snap, have := snaps[id]
	adopted := false
	if have {
		gt, meta, err := snapshot_decode(snap.blob)
		skip, ex, ok := held_tail_skip(snap.offset, tail_start, tail_end)
		if err == .None && meta.offset == snap.offset && ok {
			hsh, _ := screen_hash(gt) // before term_adopt_gt (its resize clears mode 2026)
			term_adopt_gt(t, gt)
			exact = ex && !snap.inexact && !meta.inexact
			if autotest_active do fmt.printfln("[autotest] adopted %d hash %x %s", id, hsh, exact ? "exact" : "inexact")
			term_feed_replayed(t, tail[skip:])
			adopted = true
		} else if gt != nil {
			gh.terminal_free(gt)
		}
	}
	if !adopted {
		// no usable snapshot (crash restart): a fresh terminal at the holder's size, its whole tail
		t.cols, t.rows = max(cols, 2), max(rows, 2)
		gh.terminal_resize(t.gt, t.cols, t.rows, u32(t.cell.x), u32(t.cell.y))
		term_stream_reset(t) // not through term_resize: a window streaming it starts again
		if autotest_active {
			hsh, _ := screen_hash(t.gt)
			fmt.printfln("[autotest] adopted %d hash %x inexact", id, hsh)
		}
		term_feed_replayed(t, tail)
	}
	if autotest_active && adopted && tail_start == 0 do adopt_ref_check(t, id, tail, cols, rows)
	t.inexact = !exact
	t.pty = Pty{fd = -1, held = id, pid = pid}
	t.running = true
	t.reader.eof = false
	t.changed = true
	tab.status = .Running
	if pk, is_pi := tab.kind.(Pi_Tab); is_pi {
		if s.home {
			// Atlas: the model it runs with is the one applied at its last start (its first
			// status must not take another for it: Pi_Status_Update)
			delete(agent_model_starting)
			agent_model_starting = strings.clone(state.home_model)
		} else {
			// as a restart would start it, and never looser than it was started (tokens.json,
			// MAC'd; workspace.json's flag can only add to it)
			tab.kind = Pi_Tab{readonly = chat_readonly(s.project_id) || pk.readonly || (known && saved.pi_ro)}
		}
		// the optional extensions it runs with (unknown: as now, so no restart is offered for it)
		tab.reload.extras = known ? saved.extras : pi_integration_extras()
	}
	return true
}

// Test mode: the adopted terminal against a reference fed every byte the program printed
// (the holder kept them all: its tail starts at 0), compared with the probes that show the
// state no hash covers (PR A's screen_equal_probed). Logged; the scene asserts it.
@(private = "file")
adopt_ref_check :: proc(t: ^Term, id: u32, all: []u8, cols, rows: u16) {
	ref: Term
	ref.cols, ref.rows = cols, rows
	if !term_new_gt(&ref) do return
	defer gh.terminal_free(ref.gt)
	gh.terminal_resize(ref.gt, cols, rows, u32(t.cell.x), u32(t.cell.y))
	ref.mute_replies = true
	gh.terminal_vt_write(ref.gt, raw_data(all), len(all))
	a, aok := gt_clone(ref.gt)
	b, bok := gt_clone(t.gt)
	if !aok || !bok {
		fmt.printfln("[autotest] adopted_ref %d skipped", id)
		return
	}
	defer gh.terminal_free(a)
	defer gh.terminal_free(b)
	// the same size: the adopted one may have been resized by its first layout already
	ac, ar, bc, br: u16
	gh.terminal_get(a, .Cols, &ac)
	gh.terminal_get(a, .Rows, &ar)
	gh.terminal_get(b, .Cols, &bc)
	gh.terminal_get(b, .Rows, &br)
	if ac != bc || ar != br {
		fmt.printfln("[autotest] adopted_ref %d skipped (size %dx%d vs %dx%d)", id, ac, ar, bc, br)
		return
	}
	fmt.printfln("[autotest] adopted_ref %d %s", id, screen_equal_probed(a, b) ? "equal" : "differ")
}
