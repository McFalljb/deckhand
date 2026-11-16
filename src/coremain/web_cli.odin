package main

// `deckhand-core-serve web on|off|pair|list|revoke ID|listen ADDRESS` (docs/GUIDE.md "Web access"):
// web access from a terminal on this machine, the way to it on a machine with no window (Linux).
// It dials core.sock (a core is started when none answers, as `connect` does), checks the process
// there is this user's core, and says a line hello with "peer":"web-admin" and the window token,
// which only this user can read. The core refuses it from a program in a Deckhand tab and wants
// an sshd above it (core.web_admin_check: ssh in; at the machine's screen, ssh localhost). It prints the result: the code to type in the browser, the list, or why
// not. The code goes to this terminal only.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "../core"

WEB_USAGE :: "usage: deckhand-core-serve web on|off|pair|list|revoke ID|listen ADDRESS"

web_main :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln(WEB_USAGE)
		return 2
	}
	op, arg := args[0], ""
	switch op {
	case "on", "off", "pair", "list":
		if len(args) != 1 {
			fmt.eprintln(WEB_USAGE)
			return 2
		}
	case "revoke", "listen":
		if len(args) != 2 {
			fmt.eprintln(WEB_USAGE)
			return 2
		}
		arg = args[1]
	case:
		fmt.eprintln(WEB_USAGE)
		return 2
	}
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	when core.TEST_HOOKS do core.autotest_active = core.hook_env(.Script) != ""
	fd, run, ok := core_dial("web")
	if !ok do return 1
	defer core.sock_close(fd)
	if _, why := core.core_peer_check(fd); why != "" {
		fmt.eprintln("deckhand-core-serve web:", why)
		return 1
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"id":"web","v":%d,"type":"hello","peer":"%s","op":`, core.PROTOCOL_VERSION, core.WEB_ADMIN_PEER)
	core.json_quote(&b, op)
	strings.write_string(&b, `,"arg":`)
	core.json_quote(&b, arg)
	fmt.sbprintf(&b, `,"token":"%s"}}`, core.window_token_read(run))
	strings.write_byte(&b, '\n')
	sent := core.sock_write_all(fd, b.buf[:])
	core.trust_wipe(b.buf[:])
	if !sent {
		fmt.eprintln("deckhand-core-serve web: the core closed the connection")
		return 1
	}
	line, rok := web_read_line(fd)
	if !rok {
		fmt.eprintln("deckhand-core-serve web: no answer from the core")
		return 1
	}
	if core.json_path(line, "result.ok") != "true" {
		fmt.eprintln("deckhand-core-serve web:", core.json_path(line, "result.error"))
		return 1
	}
	switch op {
	case "on":
		fmt.println("Web access is on (plain HTTP: use it on a network you trust). Pair a browser with `deckhand-core-serve web pair`.")
	case "off":
		fmt.println("Web access is off.")
	case "listen":
		fmt.println("The listen address is set.")
	case "pair":
		fmt.printfln("Open http://%s/ in the browser and type this code: %s", web_shown_address(core.json_path(line, "result.data.address")), core.json_path(line, "result.data.code"))
		fmt.printfln("It works once, for %s seconds.", core.json_path(line, "result.data.expires_in"))
	case "list":
		n := core.json_path(line, "result.data.devices.#")
		if n == "0" || n == "" {
			fmt.println("No paired browsers.")
			break
		}
		count, _ := strconv.parse_int(n)
		for i in 0 ..< count {
			p := fmt.tprintf("result.data.devices.%d.", i)
			fmt.printfln("%s  %s  paired %s, last seen %s%s", core.json_path(line, fmt.tprintf("%sid", p)), core.json_path(line, fmt.tprintf("%sname", p)), web_date(core.json_path(line, fmt.tprintf("%spaired", p))), web_date(core.json_path(line, fmt.tprintf("%slast_seen", p))), core.json_path(line, fmt.tprintf("%slinked", p)) == "true" ? "  (viewing now)" : "")
		}
	case "revoke":
		fmt.println("Revoked.")
	}
	return 0
}

// The core's one reply line (≤ 64 KiB, 10 s).
@(private = "file")
web_read_line :: proc(fd: core.Sock_Fd) -> (string, bool) {
	buf := make([dynamic]u8, context.temp_allocator)
	chunk: [4096]u8
	deadline := time.tick_add(time.tick_now(), 10 * time.Second)
	for len(buf) < 64 << 10 {
		if i := strings.index_byte(string(buf[:]), '\n'); i >= 0 do return string(buf[:i]), true
		left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline)))
		if left <= 0 || !core.sock_wait_readable(fd, left) do return "", false
		n := core.sock_read(fd, chunk[:])
		if n <= 0 do return "", false
		append(&buf, ..chunk[:n])
	}
	return "", false
}

// The listen address as a browser would type it: 0.0.0.0 or [::] is any of this machine's.
@(private = "file")
web_shown_address :: proc(addr: string) -> string {
	if strings.has_prefix(addr, "0.0.0.0:") do return fmt.tprintf("<this machine's address>:%s", addr[len("0.0.0.0:"):])
	if strings.has_prefix(addr, "[::]:") do return fmt.tprintf("<this machine's address>:%s", addr[len("[::]:"):])
	return addr
}

@(private = "file")
web_date :: proc(unix: string) -> string {
	n, _ := strconv.parse_i64(unix)
	if n <= 0 do return "never"
	t := time.unix(n, 0)
	y, m, d := time.date(t)
	return fmt.tprintf("%04d-%02d-%02d", y, int(m), d)
}
