package corewire

import "core:testing"
import "core:thread"

@(test)
mem_roundtrip :: proc(t: ^testing.T) {
	tr: Mem_Transport
	defer mem_destroy(&tr)
	win, core := mem_open(&tr)
	_, e := mem_recv(core)
	testing.expect_value(t, e, Recv_Error.Empty)
	testing.expect_value(t, mem_send(win, JSON_CHANNEL, .Data, transmute([]u8)string(`{"id":1}`)), Send_Error.None)
	testing.expect_value(t, mem_send(win, 3, .Credit, nil), Send_Error.None)
	testing.expect_value(t, mem_send(core, 3, .Data, transmute([]u8)string("out")), Send_Error.None)
	testing.expect_value(t, mem_unread(win), 2 * HEADER_SIZE + 8)
	// each direction keeps its own order; the payload is a copy that outlives later sends
	f, _ := mem_recv(core)
	testing.expect(t, f.channel == 0 && f.kind == u8(Kind.Data) && string(f.payload) == `{"id":1}`)
	for _ in 0 ..< 100 do mem_send(win, 1, .Data, make([]u8, 10_000, context.temp_allocator))
	testing.expect_value(t, string(f.payload), `{"id":1}`)
	f, _ = mem_recv(core)
	testing.expect(t, f.channel == 3 && f.kind == u8(Kind.Credit) && len(f.payload) == 0)
	f, _ = mem_recv(win)
	testing.expect(t, f.channel == 3 && string(f.payload) == "out")
	_, e = mem_recv(win)
	testing.expect_value(t, e, Recv_Error.Empty)
	// unknown kinds pass through (the receiver ignores them)
	mem_send(core, 2, Kind(200), nil)
	f, _ = mem_recv(win)
	testing.expect(t, f.kind == 200 && !is_known(f.kind))
	free_all(context.temp_allocator)
}

@(test)
mem_limits :: proc(t: ^testing.T) {
	tr: Mem_Transport
	defer mem_destroy(&tr)
	a, b := mem_open(&tr, cap = 100)
	big := make([]u8, MAX_PAYLOAD + 1, context.temp_allocator)
	testing.expect_value(t, mem_send(a, 1, .Snapshot, big, force = true), Send_Error.Too_Large)
	testing.expect_value(t, mem_unread(a), 0)
	// the cap counts unread bytes, headers included
	testing.expect_value(t, mem_send(a, 1, .Data, big[:100 - HEADER_SIZE]), Send_Error.None)
	testing.expect_value(t, mem_send(a, 1, .Data, nil), Send_Error.Full)
	testing.expect_value(t, mem_send(a, 0, .Data, big[:50], force = true), Send_Error.None) // channel 0 never blocks
	testing.expect_value(t, mem_unread(a), 100 + HEADER_SIZE + 50)
	testing.expect_value(t, mem_unread(b), 0) // the other direction is unaffected
	testing.expect_value(t, mem_send(b, 1, .Data, big[:92]), Send_Error.Full)
	testing.expect_value(t, mem_send(b, 1, .Data, big[:91 - HEADER_SIZE]), Send_Error.None)
	// reading makes room
	mem_recv(b)
	mem_recv(b)
	testing.expect_value(t, mem_unread(a), 0)
	testing.expect_value(t, mem_send(a, 1, .Data, big[:100 - HEADER_SIZE]), Send_Error.None)
	// the largest frame goes through, forced past the cap
	testing.expect_value(t, mem_send(a, 1, .Snapshot, big[:MAX_PAYLOAD], force = true), Send_Error.None)
	mem_recv(b)
	f, e := mem_recv(b)
	testing.expect_value(t, e, Recv_Error.None)
	testing.expect_value(t, len(f.payload), MAX_PAYLOAD)
	free_all(context.temp_allocator)
}

@(test)
mem_close_drains :: proc(t: ^testing.T) {
	tr: Mem_Transport
	defer mem_destroy(&tr)
	a, b := mem_open(&tr)
	mem_send(a, 0, .Data, transmute([]u8)string("last"))
	mem_send(b, 5, .Close, nil)
	mem_close(b)
	testing.expect_value(t, mem_send(a, 0, .Data, nil), Send_Error.Closed)
	testing.expect_value(t, mem_send(b, 0, .Data, nil, force = true), Send_Error.Closed)
	f, e := mem_recv(b) // what was sent before the close is still read
	testing.expect(t, e == .None && string(f.payload) == "last")
	_, e = mem_recv(b)
	testing.expect_value(t, e, Recv_Error.Closed)
	f, e = mem_recv(a)
	testing.expect(t, e == .None && f.kind == u8(Kind.Close))
	_, e = mem_recv(a)
	testing.expect_value(t, e, Recv_Error.Closed)
	free_all(context.temp_allocator)
}

// One thread sends, another receives: every frame arrives once, in order.
@(test)
mem_two_threads :: proc(t: ^testing.T) {
	tr: Mem_Transport
	defer mem_destroy(&tr)
	a, b := mem_open(&tr, cap = 4096)
	N :: 20_000
	sender := thread.create_and_start_with_poly_data(a, proc(a: Mem_End) {
		for i := 0; i < N; {
			v := u32(i)
			if mem_send(a, v, .Data, (cast([^]u8)&v)[:4]) == .None do i += 1
			else do thread.yield()
		}
		mem_close(a)
	})
	got := 0
	for {
		f, e := mem_recv(b)
		if e == .Closed do break
		if e == .Empty {thread.yield(); continue}
		ok := f.channel == u32(got) && len(f.payload) == 4 && (cast(^u32)raw_data(f.payload))^ == u32(got)
		testing.expectf(t, ok, "frame %d out of order", got) // keep draining, so the sender ends
		got += 1
		if got % 1024 == 0 do free_all(context.temp_allocator)
	}
	thread.join(sender)
	thread.destroy(sender)
	testing.expect_value(t, got, N)
	free_all(context.temp_allocator)
}
