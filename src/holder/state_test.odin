#+build darwin
package holder

// The upgrade's state (state.odin): what the old image hands the new one, round-tripped, and
// refused when it is short, too big or names fds that are not there.

import "core:c"
import "core:testing"
import "core:time"

@(test)
state_round_trip :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	spawn_ok(t, h, f, 3, `printf 'one\n'; exec /bin/cat`)
	spawn_ok(t, h, f, 5, `exit 4`)
	testing.expect(t, wait_output(t, h, f, 3, "one"))
	_, ok := exited_of(t, h, f, 5)
	testing.expect(t, ok)
	t3 := find_term(h, 3)
	append(&t3.input, ..transmute([]u8)string("pending input"))
	t3.orphan = true

	blob, fds := state_encode(h, context.temp_allocator)
	testing.expect_value(t, len(fds), 2) // both masters (an ended one stays open until RELEASE)
	dup_fds := make([]c.int, len(fds), context.temp_allocator)
	for fd, i in fds do dup_fds[i] = dup(fd)
	g, why := state_decode(blob[:], dup_fds, test_cfg())
	testing.expectf(t, g != nil, "decode: %s", why)
	if g == nil do return
	defer holder_free(g)
	testing.expect_value(t, g.instance, h.instance)
	testing.expect(t, g.key == h.key)
	testing.expect_value(t, len(g.terms), 2)
	a := find_term(g, 3)
	testing.expect(t, a != nil && a.pid == t3.pid && a.pgid == t3.pgid && a.offset == t3.offset && a.orphan)
	testing.expect_value(t, string(a.input[:]), "pending input")
	testing.expect_value(t, string(ring_bytes(&a.tail)), string(ring_bytes(&t3.tail)))
	testing.expect(t, a.master >= 0 && !a.reaped)
	b := find_term(g, 5)
	testing.expect(t, b != nil && b.reaped && b.final && b.exit.code == 4 && b.eof)
	t3.orphan = false
}

@(test)
state_refuses_bad_blobs :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	spawn_ok(t, h, f, 1, `exec /bin/cat`)
	pump(h, 20 * time.Millisecond, f)
	blob, fds := state_encode(h, context.temp_allocator)
	try :: proc(t: ^testing.T, b: []u8, fds: []c.int, what: string) {
		d := make([]c.int, len(fds), context.temp_allocator)
		for fd, i in fds do d[i] = dup(fd)
		g, _ := state_decode(b, d, test_cfg())
		testing.expectf(t, g == nil, "%s: accepted", what)
		if g != nil do holder_free(g)
		for fd in d do close(fd) // a refused decode leaves the fds to the caller
	}
	for n in ([]int{0, 3, 8, len(blob) / 2, len(blob) - 1}) do try(t, blob[:n], fds[:], "truncated")
	try(t, blob[:], nil, "no fds")
	extra := []c.int{fds[0], fds[0]}
	try(t, blob[:], extra, "an fd too many")
	bad := make([]u8, len(blob), context.temp_allocator)
	copy(bad, blob[:])
	bad[0] ~= 0xff
	try(t, bad, fds[:], "bad magic")
	copy(bad, blob[:])
	bad[4] = 99 // a newer state version
	try(t, bad, fds[:], "too new")
	// a pipe where a PTY master belongs
	p: [2]c.int
	pipe(&p)
	defer close(p[0])
	defer close(p[1])
	try(t, blob[:], []c.int{p[0]}, "not a terminal")
}
