#+build darwin
package holder

// The holder's state, as an upgrade hands it from the old image to the new one (docs/plans/
// background-core.md §7.3 step 2): the instance id and HMAC key, the dirs and socket, and per
// terminal its id, pid, pgid, size, offset, tail, the INPUT the master has not taken yet (P2)
// and an exit not yet reported. Open files go beside it (SCM_RIGHTS, upgrade.odin), named here
// by index: the listener, instance.lock and each open master.
//
// Binary, little-endian, versioned: a new image reads every STATE_V up to its own, and the dry
// run proves that before the real exec. Decoding checks every length and every fd (each used
// once, of the right type), so a short or confused blob is refused, never half-applied.

import "core:c"
import "core:encoding/endian"
import "core:strings"
import "core:sys/posix"
import "core:time"

STATE_MAGIC :: u32(0x54534844) // "DHST"
STATE_V :: u32(1)
STATE_MAX_STR :: 4096
STATE_MAX_TERMS :: 4096
STATE_MAX_INPUT :: 64 * 1024 * 1024

@(private = "file")
Writer :: struct {
	b: ^[dynamic]u8,
}

@(private = "file")
w_u8 :: proc(w: Writer, v: u8) {append(w.b, v)}
@(private = "file")
w_u16 :: proc(w: Writer, v: u16) {n: [2]u8; endian.put_u16(n[:], .Little, v); append(w.b, ..n[:])}
@(private = "file")
w_u32 :: proc(w: Writer, v: u32) {n: [4]u8; endian.put_u32(n[:], .Little, v); append(w.b, ..n[:])}
@(private = "file")
w_u64 :: proc(w: Writer, v: u64) {n: [8]u8; endian.put_u64(n[:], .Little, v); append(w.b, ..n[:])}
@(private = "file")
w_i32 :: proc(w: Writer, v: i32) {w_u32(w, transmute(u32)v)}
@(private = "file")
w_i64 :: proc(w: Writer, v: i64) {w_u64(w, transmute(u64)v)}
@(private = "file")
w_bytes :: proc(w: Writer, b: []u8) {w_u32(w, u32(len(b))); append(w.b, ..b)}

// The state and the fds it names (borrowed: still the holder's). allocator: the blob and list.
state_encode :: proc(h: ^Holder, allocator := context.allocator) -> (blob: [dynamic]u8, fds: [dynamic]c.int) {
	blob = make([dynamic]u8, allocator)
	fds = make([dynamic]c.int, allocator)
	w := Writer{&blob}
	fd_index :: proc(fds: ^[dynamic]c.int, fd: c.int) -> i32 {
		if fd < 0 do return -1
		append(fds, fd)
		return i32(len(fds) - 1)
	}
	w_u32(w, STATE_MAGIC)
	w_u32(w, STATE_V)
	w_bytes(w, transmute([]u8)h.instance)
	append(&blob, ..h.key[:])
	w_bytes(w, transmute([]u8)h.cfg.run_dir)
	w_bytes(w, transmute([]u8)h.cfg.data_dir)
	w_bytes(w, transmute([]u8)h.sock_path)
	w_i32(w, fd_index(&fds, h.listen_fd))
	w_i32(w, fd_index(&fds, h.lock_fd))
	w_u32(w, u32(len(h.terms)))
	for t in h.terms {
		w_u32(w, t.id)
		w_i32(w, i32(t.pid))
		w_i32(w, i32(t.pgid))
		w_u16(w, t.cols); w_u16(w, t.rows); w_u16(w, t.xpixel); w_u16(w, t.ypixel)
		w_u64(w, t.offset)
		flags: u8
		if t.eof do flags |= 1
		if t.reaped do flags |= 2
		if t.final do flags |= 4
		if t.released do flags |= 8
		if t.orphan do flags |= 16
		w_u8(w, flags)
		w_i64(w, t.exit.code)
		w_i64(w, t.exit.signal)
		w_i32(w, fd_index(&fds, t.master))
		w_bytes(w, ring_bytes(&t.tail))
		w_bytes(w, t.input[:])
	}
	return
}

@(private = "file")
Reader :: struct {
	b:  []u8,
	at: int,
	ok: bool,
}

@(private = "file")
r_take :: proc(r: ^Reader, n: int) -> []u8 {
	if !r.ok || n < 0 || len(r.b) - r.at < n {
		r.ok = false
		return nil
	}
	s := r.b[r.at:][:n]
	r.at += n
	return s
}
@(private = "file")
r_u8 :: proc(r: ^Reader) -> u8 {s := r_take(r, 1); return s == nil ? 0 : s[0]}
@(private = "file")
r_u16 :: proc(r: ^Reader) -> u16 {s := r_take(r, 2); v, _ := endian.get_u16(s, .Little); return v}
@(private = "file")
r_u32 :: proc(r: ^Reader) -> u32 {s := r_take(r, 4); v, _ := endian.get_u32(s, .Little); return v}
@(private = "file")
r_u64 :: proc(r: ^Reader) -> u64 {s := r_take(r, 8); v, _ := endian.get_u64(s, .Little); return v}
@(private = "file")
r_i32 :: proc(r: ^Reader) -> i32 {return transmute(i32)r_u32(r)}
@(private = "file")
r_i64 :: proc(r: ^Reader) -> i64 {return transmute(i64)r_u64(r)}
@(private = "file")
r_bytes :: proc(r: ^Reader, max_n: int) -> []u8 {
	n := int(r_u32(r))
	if n > max_n do r.ok = false
	return r_take(r, n)
}

// What kind of file an fd must be.
@(private = "file")
Fd_Kind :: enum {
	Master, // a PTY master (a character device)
	Listener, // a Unix socket
	Lock, // instance.lock (a regular file)
}

@(private = "file")
fd_is :: proc(fd: c.int, kind: Fd_Kind) -> bool {
	st: posix.stat_t
	if posix.fstat(posix.FD(fd), &st) != .OK do return false
	switch kind {
	case .Master: return posix.S_ISCHR(st.st_mode)
	case .Listener: return posix.S_ISSOCK(st.st_mode)
	case .Lock: return posix.S_ISREG(st.st_mode)
	}
	return false
}

// A holder from a state blob and its fds, in this process (cfg gives the timings; the dirs come
// from the blob). Every fd must be named exactly once and be of its kind. On success the fds are
// the holder's (close-on-exec); on failure (h nil, why) nothing is taken: the caller closes them.
state_decode :: proc(blob: []u8, fds: []c.int, cfg: Config) -> (h: ^Holder, why: string) {
	r := Reader{b = blob, ok = true}
	if r_u32(&r) != STATE_MAGIC || !r.ok do return nil, "not a holder state"
	v := r_u32(&r)
	if !r.ok || v < 1 || v > STATE_V do return nil, "a state version this holder does not read"
	used := make([]bool, len(fds), context.temp_allocator)
	take_fd :: proc(r: ^Reader, fds: []c.int, used: []bool, kind: Fd_Kind) -> (fd: c.int, ok: bool) {
		i := r_i32(r)
		if !r.ok do return -1, false
		if i == -1 do return -1, true
		if i < 0 || int(i) >= len(fds) || used[i] || !fd_is(fds[i], kind) do return -1, false
		used[i] = true
		return fds[i], true
	}
	instance := r_bytes(&r, 64)
	key := r_take(&r, 32)
	run_dir := r_bytes(&r, STATE_MAX_STR)
	data_dir := r_bytes(&r, STATE_MAX_STR)
	sock := r_bytes(&r, STATE_MAX_STR)
	if !r.ok || len(instance) == 0 do return nil, "short state (header)"
	listen_fd, lok := take_fd(&r, fds, used, .Listener)
	lock_fd, kok := take_fd(&r, fds, used, .Lock)
	if !lok || !kok do return nil, "the listener or instance.lock is missing or not what it should be"
	n := r_u32(&r)
	if !r.ok || n > STATE_MAX_TERMS do return nil, "bad terminal count"

	terms := make([dynamic]^Term, context.temp_allocator)
	fail :: proc(terms: []^Term, why: string) -> (^Holder, string) {
		for t in terms {
			t.master = -1 // not ours to close
			term_free(t)
		}
		return nil, why
	}
	for _ in 0 ..< n {
		t := new(Term)
		append(&terms, t)
		t.id = r_u32(&r)
		t.pid, t.pgid = c.int(r_i32(&r)), c.int(r_i32(&r))
		t.cols, t.rows, t.xpixel, t.ypixel = r_u16(&r), r_u16(&r), r_u16(&r), r_u16(&r)
		t.offset = r_u64(&r)
		flags := r_u8(&r)
		if flags & ~u8(31) != 0 do return fail(terms[:], "a terminal flag this holder does not know")
		t.eof, t.reaped, t.final, t.released, t.orphan = flags & 1 != 0, flags & 2 != 0, flags & 4 != 0, flags & 8 != 0, flags & 16 != 0
		t.exit.code, t.exit.signal = r_i64(&r), r_i64(&r)
		master, mok := take_fd(&r, fds, used, .Master)
		t.master = master
		tail := r_bytes(&r, cfg.tail_cap)
		input := r_bytes(&r, STATE_MAX_INPUT)
		if !r.ok || !mok do return fail(terms[:], "short or bad terminal entry")
		if t.id == 0 || t.pid <= 0 || t.cols == 0 || t.rows == 0 || u64(len(tail)) > t.offset do return fail(terms[:], "a terminal entry out of range")
		for o in terms[:len(terms) - 1] do if o.id == t.id do return fail(terms[:], "a terminal listed twice")
		ring_push(&t.tail, cfg.tail_cap, tail)
		append(&t.input, ..input)
		t.reaped_at = time.tick_now()
	}
	if r.at != len(blob) do return fail(terms[:], "trailing bytes")
	for u in used do if !u do return fail(terms[:], "an fd the state does not name")

	h = holder_alloc(cfg)
	h.cfg.run_dir = strings.clone(string(run_dir))
	h.cfg.data_dir = strings.clone(string(data_dir))
	h.owns_dirs = true
	delete(h.instance)
	h.instance = strings.clone(string(instance))
	copy(h.key[:], key)
	if len(sock) > 0 do h.sock_path = strings.clone(string(sock))
	h.listen_fd, h.lock_fd = listen_fd, lock_fd
	if h.listen_fd >= 0 do set_nonblock(h.listen_fd)
	for fd in fds do set_cloexec(fd)
	for t in terms {
		if t.master >= 0 do set_nonblock(t.master)
		append(&h.terms, t)
	}
	return h, ""
}
