package core

import "core:math/rand"
import "core:sys/posix"
import "core:testing"
import "core:time"
import cw "../corewire"
import "../trust"

// One vector, shared with integrations/pi/test/unit.test.ts (helloProof): the two implementations
// agree byte for byte. (Also computed independently with Python's hmac.)
HELLO_VECTOR_TOKEN :: "abababababababababababababababababababababababababababababababab"
HELLO_VECTOR_ID :: "e05f8d531fd4524dc252476e8c9c27457a014664e4d353b0e4f228fefab4fe66"
HELLO_VECTOR_CORE :: "38531696492ecb189bf763d4ee588fe3ffad3e29eba39aca058b3835db87bc63"
HELLO_VECTOR_CLIENT :: "a01941e02678fa7489ffb892cb562796a934231cc474c246cb64cf900c36f9e9"

@(test)
hello_proof_vector :: proc(t: ^testing.T) {
	key := token_hash(HELLO_VECTOR_TOKEN)
	id := hex32(hello_token_id(key))
	testing.expect_value(t, id, HELLO_VECTOR_ID)
	cn, sn := "0101010101010101010101010101010101010101010101010101010101010101", "0202020202020202020202020202020202020202020202020202020202020202"
	testing.expect_value(t, hex32(hello_proof(key, "core", id, cn, sn, 4242)), HELLO_VECTOR_CORE)
	testing.expect_value(t, hex32(hello_proof(key, "client", id, cn, sn, 4242)), HELLO_VECTOR_CLIENT)
	// every input counts
	testing.expect(t, hex32(hello_proof(key, "client", id, cn, sn, 4243)) != HELLO_VECTOR_CLIENT)
	testing.expect(t, hex32(hello_proof(key, "client", id, sn, cn, 4242)) != HELLO_VECTOR_CLIENT)
	testing.expect(t, hex64_ok(HELLO_VECTOR_ID) && !hex64_ok("E05F8D531FD4524DC252476E8C9C27457A014664E4D353B0E4F228FEFAB4FE66") && !hex64_ok("ab"))
	testing.expect(t, hex64_equal(HELLO_VECTOR_ID, HELLO_VECTOR_ID) && !hex64_equal(HELLO_VECTOR_ID, HELLO_VECTOR_CORE))
	free_all(context.temp_allocator)
}

// The socket transport with the core's peer check (trust.peer_still over the token read at
// accept): frames from the process that connected pass; once a forked child writes on the same
// fd, the transport drops the connection before acting on its bytes (§5.3, §10.3 M4-B).
@(test)
transport_drops_a_forked_writer :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	at_accept := trust.peer_read(fds[1])
	testing.expect(t, at_accept.ok, "peer token")
	check :: proc(fd: posix.FD, data: rawptr) -> bool {
		return trust.peer_still((^trust.Peer)(data)^, trust.peer_read(fd)) == .Allow
	}
	tr: cw.Sock_Transport
	cw.sock_open(&tr, fds[1], peer_check = check, peer_data = &at_accept)
	defer cw.sock_destroy(&tr)
	frame := make([dynamic]u8, context.temp_allocator)
	cw.encode(&frame, 0, .Data, transmute([]u8)string("from the parent"))
	posix.write(fds[0], raw_data(frame), len(frame))
	f, e := wait_frame(&tr)
	testing.expect(t, e == .None && string(f.payload) == "from the parent")
	// a child writes, then waits until the parent has looked (so its token is live, not gone)
	gate: [2]posix.FD
	posix.pipe(&gate)
	pid := posix.fork()
	if pid == 0 {
		posix.close(gate[1])
		posix.write(fds[0], raw_data(frame), len(frame))
		b: [1]u8
		posix.read(gate[0], raw_data(b[:]), 1)
		posix._exit(0)
	}
	posix.close(gate[0])
	_, e = wait_frame(&tr)
	testing.expect_value(t, e, cw.Recv_Error.Closed)
	testing.expect_value(t, cw.sock_reason(&tr), cw.Close_Reason.Peer_Changed)
	posix.close(gate[1])
	st: i32
	posix.waitpid(pid, &st, {})
	posix.close(fds[0])
	free_all(context.temp_allocator)
}

@(private = "file")
wait_frame :: proc(tr: ^cw.Sock_Transport) -> (cw.Frame, cw.Recv_Error) {
	start := time.tick_now()
	for time.tick_since(start) < 2 * time.Second {
		f, e := cw.sock_recv(tr)
		if e != .Empty do return f, e
		cw.sock_wait(tr, 5)
	}
	return {}, .Empty
}

// A fuzz pass over the hello's decoding (well under 1 s): mutated hello, challenge and proof lines
// never crash parse_request, and what it accepts as a challenge's fields is checked by hex64_ok
// before use (conn_challenge, conn_proof).
@(test)
hello_decoder_fuzz :: proc(t: ^testing.T) {
	seeds := [?]string {
		`{"id":"1","v":1,"type":"hello","token":"abababababababababababababababababababababababababababababababab","challenge":true}`,
		`{"id":"1","v":1,"type":"hello","token_id":"e05f8d531fd4524dc252476e8c9c27457a014664e4d353b0e4f228fefab4fe66","nonce":"0101010101010101010101010101010101010101010101010101010101010101"}`,
		`{"id":"2","v":1,"type":"hello.proof","proof":"a01941e02678fa7489ffb892cb562796a934231cc474c246cb64cf900c36f9e9","framed":true}`,
	}
	state := rand.create(t.seed)
	gen := rand.default_random_generator(&state)
	start := time.tick_now()
	n := 0
	for n < 20_000 && time.tick_since(start) < 700 * time.Millisecond {
		n += 1
		b := make([dynamic]u8, context.temp_allocator)
		append(&b, seeds[rand.int_max(len(seeds), gen)])
		for _ in 0 ..< 1 + rand.int_max(4, gen) {
			if len(b) == 0 do break
			at := rand.int_max(len(b), gen)
			switch rand.int_max(4, gen) {
			case 0: b[at] ~= u8(1 << uint(rand.int_max(8, gen)))
			case 1: inject_at(&b, at, u8(rand.int_max(256, gen)))
			case 2: ordered_remove(&b, at)
			case 3: inject_at(&b, at, u8(`"`[0]))
			}
		}
		m, err := parse_request(string(b[:]), context.temp_allocator)
		if err == "" && m.type == "hello" && m.token_id != "" {
			// what conn_challenge would go on with
			if hex64_ok(m.token_id) && hex64_ok(m.nonce) do testing.expect(t, len(m.token_id) == 64)
		}
		if n % 512 == 0 do free_all(context.temp_allocator)
	}
	testing.expect(t, n > 1000, "the fuzz pass ran")
	free_all(context.temp_allocator)
}
