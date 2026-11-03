package main

// A tiny control-socket client for testing and scripts:
//
//   pi-desk --ctl [--wait MS] JSON...
//
// Connects to $PI_DESK_SOCKET, says hello with $PI_DESK_TOKEN, then sends
// each JSON argument in order and prints every line it receives. A plain
// command object ({"type":"get_state"}) is wrapped in a command envelope; an
// object with "v" is sent as it is (e.g. {"id":"s","v":1,"type":"subscribe"}
// or a fake bridge's {"id":"b","v":1,"type":"pi.status",...}). It waits for
// each request's reply (and for `finished` when the reply is pending), then
// keeps printing incoming lines for --wait MS. Exit status 1 if a reply had
// "ok": false. Get a token with `pi-desk --print-token script DIR`.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

ctl_main :: proc(args: []string) -> int {
	path := os.get_env("PI_DESK_SOCKET", context.allocator)
	token := os.get_env("PI_DESK_TOKEN", context.allocator)
	if path == "" || token == "" {
		fmt.eprintln("pi-desk --ctl: PI_DESK_SOCKET and PI_DESK_TOKEN must be set (see pi-desk --print-token)")
		return 2
	}
	rest := args
	wait_ms := 0
	if len(rest) >= 2 && rest[0] == "--wait" {
		wait_ms, _ = strconv.parse_int(rest[1])
		rest = rest[2:]
	}
	fd, ok := sock_connect(path)
	if !ok {
		fmt.eprintln("pi-desk --ctl: cannot connect to", path)
		return 1
	}
	defer sock_close(fd)
	r := Ctl_Reader{fd = fd}
	hello := fmt.tprintf(`{{"id":"hello","v":%d,"type":"hello","token":"%s"}}`, PROTOCOL_VERSION, token)
	if !ctl_send(fd, hello) do return 1
	line, got := ctl_next(&r, 5000)
	if !got || json_path(line, "result.ok") != "true" {
		fmt.eprintln("pi-desk --ctl: hello failed:", line)
		return 1
	}
	status := 0
	for arg, i in rest {
		v, err := json.parse_string(arg, .JSON, true, context.temp_allocator)
		obj, is_obj := v.(json.Object)
		if err != nil || !is_obj {
			fmt.eprintln("pi-desk --ctl: not a JSON object:", arg)
			return 2
		}
		id := fmt.tprintf("c%d", i + 1)
		out: string
		if _, raw := obj["v"]; raw {
			out = arg
			id, _ = obj["id"].(json.String) // no id: nothing to wait for
		} else {
			out = fmt.tprintf(`{{"id":"%s","v":%d,"type":"command","command":%s}}`, id, PROTOCOL_VERSION, arg)
		}
		if !ctl_send(fd, out) do return 1
		if id == "" do continue
		// print until our reply, then (if pending) until its finished event
		finish := ""
		deadline := time.tick_now()
		for time.tick_since(deadline) < 60 * time.Second {
			l, ok2 := ctl_next(&r, 1000)
			if !ok2 {
				if r.closed do return 1
				continue
			}
			fmt.println(l)
			if finish == "" && json_path(l, "id") == id {
				if json_path(l, "result.ok") == "false" do status = 1
				if json_path(l, "result.pending") != "true" do break
				finish = json_path(l, "request_id")
			} else if finish != "" && json_path(l, "event") == "finished" && json_path(l, "request_id") == finish {
				if json_path(l, "result.ok") == "false" do status = 1
				break
			}
		}
	}
	end := time.tick_now()
	for time.tick_since(end) < time.Duration(wait_ms) * time.Millisecond {
		if l, ok2 := ctl_next(&r, 100); ok2 do fmt.println(l)
		else if r.closed do break
	}
	return status
}

@(private = "file")
Ctl_Reader :: struct {
	fd:     Sock_Fd,
	buf:    [dynamic]u8,
	closed: bool,
}

@(private = "file")
ctl_send :: proc(fd: Sock_Fd, line: string) -> bool {
	ok := sock_write_all(fd, transmute([]u8)strings.concatenate({line, "\n"}, context.temp_allocator))
	if !ok do fmt.eprintln("pi-desk --ctl: connection closed")
	return ok
}

// The next line (temp allocator), waiting up to ms.
@(private = "file")
ctl_next :: proc(r: ^Ctl_Reader, ms: int) -> (string, bool) {
	deadline := time.tick_now()
	for {
		if i := strings.index_byte(string(r.buf[:]), '\n'); i >= 0 {
			line := strings.clone(string(r.buf[:i]), context.temp_allocator)
			remove_range(&r.buf, 0, i + 1)
			return line, true
		}
		if r.closed do return "", false
		left := ms - int(time.duration_milliseconds(time.tick_since(deadline)))
		if left <= 0 || !sock_wait_readable(r.fd, left) do return "", false
		chunk: [16 * 1024]u8
		n := sock_read(r.fd, chunk[:])
		if n <= 0 {
			r.closed = true
			continue
		}
		append(&r.buf, ..chunk[:n])
	}
}
