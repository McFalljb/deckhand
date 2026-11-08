package holder

// A terminal's tail: the last `cap` bytes it printed (oldest dropped). Grows to cap on demand,
// so a quiet terminal costs little; then wraps.
Ring :: struct {
	buf:  [dynamic]u8,
	head: int, // once full: where the oldest byte is (and the next write goes)
}

ring_push :: proc(r: ^Ring, cap: int, b: []u8) {
	b := b
	if cap <= 0 do return
	if len(b) >= cap {
		clear(&r.buf)
		append(&r.buf, ..b[len(b) - cap:])
		r.head = 0
		return
	}
	if len(r.buf) < cap {
		take := min(cap - len(r.buf), len(b))
		append(&r.buf, ..b[:take])
		b = b[take:]
	}
	for len(b) > 0 {
		k := copy(r.buf[r.head:], b)
		r.head = (r.head + k) % cap
		b = b[k:]
	}
}

ring_len :: proc(r: ^Ring) -> int {return len(r.buf)}

// The kept bytes, oldest first, in one slice (allocated with `allocator`).
ring_bytes :: proc(r: ^Ring, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, len(r.buf), allocator)
	n := copy(out, r.buf[r.head:])
	copy(out[n:], r.buf[:r.head])
	return out
}

ring_destroy :: proc(r: ^Ring) {delete(r.buf)}
