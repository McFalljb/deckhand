package pi_desk_cli

// pi-desk's control socket, client side (pi-desk docs/PROTOCOL.md §1–2): NDJSON over the Unix
// socket in PI_DESK_SOCKET. One hello with the Claude tab's token (PI_DESK_CLAUDE_TOKEN,
// multi-use; never printed or logged), then commands one at a time; a `pending` reply is closed
// by a `finished` event with its request_id. Closing the connection (exit, a timeout) makes
// pi-desk cancel what this connection still runs.

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"

PROTOCOL_VERSION :: 1

Transport :: struct {
	// sends one command object (JSON) and returns its final result; err: our own words
	call:  proc(t: ^Transport, cmd: string, timeout_ms: int) -> (result: json.Object, err: string),
	data:  rawptr,
	// the socket (real transport)
	fd:    posix.FD,
	open:  bool,
	buf:   [dynamic]u8,
	n:     int,
	path:  string,
	token: string,
	hello_ms: int,
}

real_transport :: proc(path, token: string, hello_ms := 5000) -> Transport {
	return Transport{call = sock_call, path = path, token = token, hello_ms = hello_ms, fd = -1}
}

transport_close :: proc(t: ^Transport) {
	if t.open do posix.close(t.fd)
	t.open = false
}

@(private = "file")
sock_connect :: proc(path: string) -> (posix.FD, bool) {
	addr: posix.sockaddr_un
	if len(path) == 0 || len(path) >= len(addr.sun_path) do return -1, false
	addr.sun_family = .UNIX
	for i in 0 ..< len(path) do addr.sun_path[i] = c.char(path[i])
	when ODIN_OS == .Darwin do addr.sun_len = u8(size_of(addr))
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1, false
	posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC) // never inherited by anything we start
	when ODIN_OS == .Darwin {
		one: c.int = 1
		SO_NOSIGPIPE :: 0x1022
		posix.setsockopt(fd, posix.SOL_SOCKET, posix.Sock_Option(SO_NOSIGPIPE), &one, size_of(one))
	}
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

@(private = "file")
sock_send :: proc(fd: posix.FD, line: string) -> bool {
	data := transmute([]u8)strings.concatenate({line, "\n"})
	rest := data
	for len(rest) > 0 {
		n := posix.send(fd, raw_data(rest), len(rest), {})
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do return false
		rest = rest[n:]
	}
	return true
}

// The next line, waiting until the deadline. ok false: closed or timed out (timed_out says which).
@(private = "file")
next_line :: proc(t: ^Transport, deadline: time.Tick, limit_ms: int) -> (line: string, ok: bool, timed_out: bool) {
	for {
		if i := strings.index_byte(string(t.buf[:]), '\n'); i >= 0 {
			line = strings.clone(strings.trim_right(string(t.buf[:i]), "\r"))
			remove_range(&t.buf, 0, i + 1)
			return line, true, false
		}
		left := limit_ms - int(time.duration_milliseconds(time.tick_since(deadline)))
		if left <= 0 do return "", false, true
		pfd := posix.pollfd{fd = t.fd, events = {.IN}}
		r := posix.poll(&pfd, 1, c.int(min(left, 1000)))
		if r < 0 && posix.errno() != .EINTR do return "", false, false
		if r <= 0 do continue
		chunk: [16 * 1024]u8
		n := posix.read(t.fd, raw_data(chunk[:]), len(chunk))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do return "", false, false
		append(&t.buf, ..chunk[:n])
		if len(t.buf) > 64 << 20 do return "", false, false
	}
}

@(private = "file")
sock_call :: proc(t: ^Transport, cmd: string, timeout_ms: int) -> (result: json.Object, err: string) {
	if !t.open {
		fd, ok := sock_connect(t.path)
		if !ok do return nil, "cannot connect to Deckhand (is it still running?)"
		t.fd, t.open = fd, true
		hello := fmt.aprintf(`{{"id":"h","v":%d,"type":"hello","token":%s}}`, PROTOCOL_VERSION, quoted(t.token))
		if !sock_send(t.fd, hello) {
			transport_close(t)
			return nil, "Deckhand closed the connection"
		}
		start := time.tick_now()
		line, got, _ := next_line(t, start, t.hello_ms)
		if !got {
			transport_close(t)
			return nil, "Deckhand did not answer the hello"
		}
		o, _ := parse_obj(line)
		r := get_obj(o, "result")
		if !is_true(r, "ok") {
			transport_close(t)
			why := get_text(r, "error")
			if why == "unknown token" do return nil, "Deckhand refused this Claude tab's token (the tab was closed or restarted)"
			return nil, fmt.aprintf("Deckhand refused the connection: %s", why != "" ? why : "no reason given")
		}
	}
	t.n += 1
	id := fmt.aprintf("c%d", t.n)
	if !sock_send(t.fd, fmt.aprintf(`{{"id":%s,"v":%d,"type":"command","command":%s}}`, quoted(id), PROTOCOL_VERSION, cmd)) {
		transport_close(t)
		return nil, "Deckhand closed the connection"
	}
	start := time.tick_now()
	request_id: i64 = -1
	for {
		line, got, timed_out := next_line(t, start, timeout_ms)
		if !got {
			transport_close(t) // pi-desk cancels what it still runs for us
			if timed_out do return nil, fmt.aprintf("no answer from Deckhand within %d s", timeout_ms / 1000)
			return nil, "Deckhand closed the connection"
		}
		o, ok := parse_obj(line)
		if !ok do continue
		type := get_text(o, "type")
		if request_id < 0 && type == "result" && get_text(o, "id") == id {
			r := get_obj(o, "result")
			if r == nil do return nil, "Deckhand sent a malformed reply"
			if !is_true(r, "pending") do return r, ""
			rid, has := get_int(o, "request_id")
			if !has do return nil, "Deckhand sent a pending reply without a request id"
			request_id = rid
			continue
		}
		if request_id >= 0 && type == "event" && get_text(o, "event") == "finished" {
			if rid, has := get_int(o, "request_id"); has && rid == request_id {
				r := get_obj(o, "result")
				if r == nil do return nil, "Deckhand sent a malformed finished event"
				return r, ""
			}
		}
	}
}
