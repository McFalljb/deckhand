package core

// Web access (#148, docs/PROTOCOL.md §5c): a browser as the user's window. The core listens on
// a configurable address over plain HTTP (web_http.odin), serves the web client (web_assets.odin),
// pairs browsers with a one-time code and carries the framed wire over a WebSocket, one frame per
// binary message, into the window's link (window_link.odin, `web` set).
//
// Off by default (set_web_access, User_Here, confirmed like set_machines_reachable). While on, a
// separate core (`deckhand-core-serve serve`) listens on settings.web_listen ("" =
// WEB_LISTEN_DEFAULT) and does not idle out. No TLS of its own and no accounts: firewalls, a VPN
// such as Tailscale, or a proxy with HTTPS in front are the user's business (GUIDE.md "Web access").
//
// Pairing: web_pair (User_Here: this machine's window, or `deckhand-core-serve web pair` in a
// terminal there) opens an 8-character code from WEB_CODE_ALPHABET for WEB_CODE_LIFE; it is single
// use and void after WEB_CODE_TRIES wrong tries. The browser posts it to /api/pair and gets a
// 256-bit token as an HttpOnly, SameSite=Strict cookie. <data>/web-devices.json (0600) keeps only
// the token's SHA-256, with the browser's name, when it was paired and last seen; a token unused for
// WEB_DEVICE_IDLE expires. web_revoke forgets one and closes its live link. Neither the code nor a
// token is ever logged, put in State or in an event (the result of web_pair is its caller's only).
//
// Threads: the HTTP side (accept and connection threads) reads and changes `web` under web.mu;
// the main thread starts and stops the listener (web_tick), saves the file and closes links.

import "base:runtime"
import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

import jg "../jsonguard"

WEB_LISTEN_DEFAULT :: "0.0.0.0:7433"
WEB_DEVICES_FILE :: "web-devices.json"
WEB_CODE_ALPHABET :: "ABCDEFGHJKMNPQRSTUVWXYZ23456789" // no I, L, O, 0, 1
WEB_CODE_LEN :: 8
WEB_CODE_LIFE :: 2 * time.Minute
WEB_CODE_TRIES :: 5
WEB_DEVICE_IDLE_S :: 60 * 24 * 3600 // a token unused this long expires (and the cookie's Max-Age)
WEB_DEVICES_MAX :: 32
WEB_NAME_MAX :: 64

WEB_ACCESS_QUESTION :: "Allow browsers to connect to this machine? A browser you pair acts as you here: it can see and drive every session, type into its shells and reach the machines this one is linked to. Deckhand serves it over plain HTTP: anyone who can see the traffic on the network can read it and take over the session, so use it only on a network you trust (Tailscale, a VPN) or behind an HTTPS proxy."

Set_Web_Access :: struct {
	on:      bool,
	confirm: string, // turning it on: the user confirms first (WEB_ACCESS_QUESTION)
}

Set_Web_Listen :: struct {
	address: string, // "host:port" (IPv4, or [IPv6]); "" = WEB_LISTEN_DEFAULT
}

Web_Pair :: struct {} // a pairing code: data {code, expires_in, address}

Web_Devices :: struct {} // the paired browsers: data {devices [{id, name, paired, last_seen, linked}]}

Web_Revoke :: struct {
	id: string, // a paired browser's id (web_devices)
}

// A paired browser (web-devices.json).
Web_Device :: struct {
	id:        string, // heap: 12 hex digits, random
	name:      string, // heap: what the browser called itself (text_clean)
	hash:      [32]u8, // SHA-256 of its token
	paired:    i64, // unix seconds
	last_seen: i64,
}

// What the window's Settings › Machines › Web access shows (state.live.web; core_live.odin).
Web_Live :: struct {
	listening: bool,
	address:   string, // what it listens on ("" = nothing)
	error:     string, // why it does not ("" = none)
	pairing:   i64, // a code is open until this (unix seconds; 0 = none). The code is never here
	devices:   []Web_Device_Live,
}

Web_Device_Live :: struct {
	id, name:          string,
	paired, last_seen: i64,
	linked:            bool, // its link is the attached one
}

@(private = "file")
Web_Code :: struct {
	code:  [WEB_CODE_LEN]u8,
	until: i64, // unix seconds (0: none open)
	tries: int,
}

@(private)
web: struct {
	mu:        sync.Mutex,
	loaded:    bool,
	devices:   [dynamic]Web_Device,
	dirty:     bool, // devices changed: the main thread saves
	code:      Web_Code,
	kick:      [dynamic]string, // heap: devices whose live link must close (an unpair over HTTP)
	// the listener (main thread; the accept thread reads fd and epoch)
	fd:        Sock_Fd,
	bound:     string, // heap: the address it listens on
	error:     string, // heap
	failed:    string, // heap: the address that last failed, tried again after WEB_RETRY
	failed_at: time.Tick,
	accept:    ^thread.Thread,
	epoch:     u64, // atomic: bumped at each stop; connection threads of an older epoch end
	conns:     int, // atomic: connection threads (HTTP, before an upgrade)
	relays:    int, // atomic: WebSocket relays
	expired_at: time.Tick, // the last expiry sweep
}

@(private = "file")
WEB_RETRY :: 5 * time.Second

// ---- the setting ----

// The address to listen on: the setting, else the default.
web_listen_address :: proc() -> string {
	a := strings.trim_space(state.settings.web_listen)
	return a == "" ? WEB_LISTEN_DEFAULT : a
}

Web_Addr :: struct {
	v6:   bool,
	ip:   [16]u8, // v4: the first 4
	port: u16,
	host: string, // as written (the brackets dropped)
}

// "1.2.3.4:7433", "0.0.0.0:7433", "[::]:7433", "[fd7a::1]:80". ok false: not one.
web_addr_parse :: proc(s: string) -> (a: Web_Addr, ok: bool) {
	host, port: string
	if strings.has_prefix(s, "[") {
		end := strings.index_byte(s, ']')
		if end < 0 || end + 1 >= len(s) || s[end + 1] != ':' do return {}, false
		host, port = s[1:end], s[end + 2:]
		a.v6 = true
	} else {
		c := strings.last_index_byte(s, ':')
		if c <= 0 do return {}, false
		host, port = s[:c], s[c + 1:]
		if strings.index_byte(host, ':') >= 0 do return {}, false // IPv6 needs its brackets
	}
	if len(port) == 0 || len(port) > 5 || len(host) == 0 || len(host) > 45 do return {}, false
	for ch in transmute([]u8)port do if ch < '0' || ch > '9' do return {}, false
	p, pok := strconv.parse_uint(port, 10)
	if !pok || p == 0 || p > 65535 do return {}, false
	a.port = u16(p)
	ch := strings.clone_to_cstring(host, context.temp_allocator)
	if a.v6 {
		if posix.inet_pton(.INET6, ch, &a.ip[0]) != .SUCCESS do return {}, false
	} else if posix.inet_pton(.INET, ch, &a.ip[0]) != .SUCCESS do return {}, false
	a.host = host
	return a, true
}

// ---- devices ----

web_devices_path :: proc() -> string {
	if home_root == "" do return ""
	return fmt.tprintf("%s/%s", strings.trim_right(home_root, "/"), WEB_DEVICES_FILE)
}

// Reads the paired browsers (web.mu held; once). A token unused for WEB_DEVICE_IDLE_S is dropped.
@(private = "file")
web_load_locked :: proc() {
	if web.loaded do return
	web.loaded = true
	heap := runtime.heap_allocator()
	web.devices = make([dynamic]Web_Device, heap)
	path := web_devices_path()
	if path == "" do return
	b, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	list := web_devices_decode(string(b), heap)
	for d in list do append(&web.devices, d)
	delete(list, heap)
	if web_expire_locked(time.to_unix_seconds(time.now())) do web.dirty = true
}

// The file's devices (allocator); a malformed entry is skipped.
web_devices_decode :: proc(text: string, allocator := context.allocator) -> []Web_Device {
	out := make([dynamic]Web_Device, allocator)
	v, jerr := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if jerr != nil do return out[:]
	obj, _ := v.(json.Object)
	arr, _ := obj["devices"].(json.Array)
	for e in arr {
		o, ok := e.(json.Object)
		if !ok || len(out) >= WEB_DEVICES_MAX do continue
		id, _ := o["id"].(json.String)
		name, _ := o["name"].(json.String)
		h, _ := o["hash"].(json.String)
		paired, _ := o["paired"].(json.Integer)
		seen, _ := o["last_seen"].(json.Integer)
		if len(id) != 12 || !hex64_ok(h) do continue
		d := Web_Device{paired = paired, last_seen = seen}
		raw, hok := hex.decode(transmute([]u8)h, context.temp_allocator)
		if !hok || len(raw) != 32 do continue
		copy(d.hash[:], raw)
		d.id = strings.clone(id, allocator)
		d.name = strings.clone(text_clean(name, WEB_NAME_MAX), allocator)
		append(&out, d)
	}
	return out[:]
}

web_devices_encode :: proc(list: []Web_Device) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"v":1,"devices":[`)
	for d, i in list {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"id":`)
		json_quote(&b, d.id)
		strings.write_string(&b, `,"name":`)
		json_quote(&b, d.name)
		fmt.sbprintf(&b, `,"hash":"%s","paired":%d,"last_seen":%d}}`, hex32(d.hash), d.paired, d.last_seen)
	}
	strings.write_string(&b, "]}\n")
	return strings.to_string(b)
}

// Drops tokens unused for WEB_DEVICE_IDLE_S (web.mu held). True: one went.
@(private = "file")
web_expire_locked :: proc(now: i64) -> bool {
	gone := false
	for i := len(web.devices) - 1; i >= 0; i -= 1 {
		d := web.devices[i]
		seen := max(d.last_seen, d.paired)
		if now - seen <= WEB_DEVICE_IDLE_S do continue
		web_device_free(&web.devices[i])
		ordered_remove(&web.devices, i)
		gone = true
	}
	return gone
}

@(private = "file")
web_device_free :: proc(d: ^Web_Device) {
	heap := runtime.heap_allocator()
	delete(d.id, heap)
	delete(d.name, heap)
	d^ = {}
}

// Main thread: writes the file when the devices changed (0600, temp file and rename).
@(private = "file")
web_save :: proc() {
	sync.lock(&web.mu)
	if !web.dirty {
		sync.unlock(&web.mu)
		return
	}
	web.dirty = false
	text := web_devices_encode(web.devices[:])
	sync.unlock(&web.mu)
	path := web_devices_path()
	if path == "" do return
	tmp := fmt.tprintf("%s.new", path)
	os.remove(tmp)
	fd := posix.open(strings.clone_to_cstring(tmp, context.temp_allocator), {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 {
		log_ln("Deckhand: cannot write", tmp)
		return
	}
	ok := posix.write(fd, raw_data(text), uint(len(text))) == len(text)
	posix.close(fd)
	if !ok || posix.rename(strings.clone_to_cstring(tmp, context.temp_allocator), strings.clone_to_cstring(path, context.temp_allocator)) != 0 {
		os.remove(tmp)
		log_ln("Deckhand: cannot write", path)
	}
}

// The browser whose cookie holds tok (any thread): its id and name (temp allocator), and last seen
// set to now. ok false: none (or not a token's shape). Every device is compared, in constant time.
web_token_device :: proc(tok: string, now: i64) -> (id, name: string, ok: bool) {
	if !hex64_ok(tok) do return
	h := token_hash(tok)
	sync.guard(&web.mu)
	web_load_locked()
	at := -1
	for &d, i in web.devices do if crypto.compare_constant_time(h[:], d.hash[:]) == 1 do at = i
	if at < 0 do return
	d := &web.devices[at]
	if now - max(d.last_seen, d.paired) > WEB_DEVICE_IDLE_S do return // expired: the sweep drops it
	if now - d.last_seen >= 60 { 	// written at most once a minute
		d.last_seen = now
		web.dirty = true
	}
	return strings.clone(d.id, context.temp_allocator), strings.clone(d.name, context.temp_allocator), true
}

// Forgets the browser of tok (an unpair over HTTP, any thread): its live link closes at the next
// tick. False: no such token.
web_token_forget :: proc(tok: string) -> bool {
	if !hex64_ok(tok) do return false
	h := token_hash(tok)
	sync.guard(&web.mu)
	web_load_locked()
	for &d, i in web.devices do if crypto.compare_constant_time(h[:], d.hash[:]) == 1 {
		if web.kick == nil do web.kick = make([dynamic]string, runtime.heap_allocator())
		append(&web.kick, strings.clone(d.id, runtime.heap_allocator()))
		web_device_free(&d)
		ordered_remove(&web.devices, i)
		web.dirty = true
		return true
	}
	return false
}

// ---- pairing ----

// What a typed code becomes before it is compared: dashes and spaces dropped, upper case. ""
// if it is not WEB_CODE_LEN characters of the alphabet.
web_code_normal :: proc(typed: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for ch in transmute([]u8)typed {
		switch ch {
		case '-', ' ': continue
		case 'a' ..= 'z': strings.write_byte(&b, ch - 32)
		case: strings.write_byte(&b, ch)
		}
		if strings.builder_len(b) > WEB_CODE_LEN do return ""
	}
	s := strings.to_string(b)
	if len(s) != WEB_CODE_LEN do return ""
	for ch in transmute([]u8)s do if strings.index_byte(WEB_CODE_ALPHABET, ch) < 0 do return ""
	return s
}

// A fresh code (replacing one still open), for WEB_CODE_LIFE from now (unix seconds). Temp.
web_code_open :: proc(now: i64) -> (code: string, until: i64) {
	c: Web_Code
	alphabet := WEB_CODE_ALPHABET
	n := len(alphabet)
	limit := 256 - 256 % n // rejection sampling: every letter equally likely
	for i := 0; i < WEB_CODE_LEN; {
		r: [16]u8
		crypto.rand_bytes(r[:])
		for x in r do if int(x) < limit && i < WEB_CODE_LEN {
			c.code[i] = alphabet[int(x) % n]
			i += 1
		}
	}
	c.until = now + i64(WEB_CODE_LIFE / time.Second)
	sync.guard(&web.mu)
	web.code = c
	return strings.clone(string(c.code[:]), context.temp_allocator), c.until
}

// The code shown as typed: ABCD-EFGH.
web_code_shown :: proc(code: string) -> string {
	if len(code) != WEB_CODE_LEN do return code
	return fmt.tprintf("%s-%s", code[:4], code[4:])
}

Web_Pair_Answer :: enum u8 {
	Paired,
	Wrong, // not the open code (a try counted)
	None, // no code open (none, used, expired or void after WEB_CODE_TRIES)
	Full, // WEB_DEVICES_MAX browsers paired
}

// A browser's try at the code (any thread). Paired: token is its new cookie (temp), name kept.
// The code is compared in constant time; a right one is used up, a wrong one counts.
web_pair_try :: proc(typed, name: string, now: i64) -> (a: Web_Pair_Answer, token: string) {
	got := web_code_normal(typed)
	sync.guard(&web.mu)
	web_load_locked()
	c := &web.code
	if c.until == 0 || now > c.until || c.tries >= WEB_CODE_TRIES {
		c^ = {}
		return .None, ""
	}
	want := c.code
	right := len(got) == WEB_CODE_LEN && crypto.compare_constant_time(transmute([]u8)got, want[:]) == 1
	if !right {
		c.tries += 1
		if c.tries >= WEB_CODE_TRIES do c^ = {}
		return .Wrong, ""
	}
	c^ = {} // single use
	if len(web.devices) >= WEB_DEVICES_MAX do return .Full, ""
	raw: [32]u8
	crypto.rand_bytes(raw[:])
	token = hex32(raw)
	idb: [6]u8
	crypto.rand_bytes(idb[:])
	heap := runtime.heap_allocator()
	nm := text_clean(strings.trim_space(name), WEB_NAME_MAX)
	if nm == "" do nm = "Browser"
	append(&web.devices, Web_Device{id = string(hex.encode(idb[:], heap)), name = strings.clone(nm, heap), hash = token_hash(token), paired = now, last_seen = now})
	web.dirty = true
	return .Paired, token
}

// ---- commands (main thread) ----

web_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	#partial switch c in cmd {
	case Set_Web_Access:
		if state.settings.web_access == c.on do return {ok = true}, false
		// on: the user confirms first (a saved setting coming back, or the terminal's
		// `deckhand-core-serve web on`, does not ask)
		if c.on && caller.kind != .Internal {
			gr, go_on, ch := confirm_gate(cmd, .Settings_Write, caller, c.confirm, WEB_ACCESS_QUESTION, force_ask = true)
			if !go_on do return gr, ch
		}
		state.settings.web_access = c.on
		if !c.on {
			sync.guard(&web.mu)
			web.code = {}
		}
		return {ok = true}, true
	case Set_Web_Listen:
		a := strings.trim_space(c.address)
		if a != "" {
			if _, ok := web_addr_parse(a); !ok do return fail("give an address and a port: 0.0.0.0:7433, 127.0.0.1:7433, a Tailscale address such as 100.101.102.103:7433, or [::]:7433"), false
		}
		if a == WEB_LISTEN_DEFAULT do a = ""
		if a == state.settings.web_listen do return {ok = true}, false
		state.settings.web_listen = strings.clone(a)
		return {ok = true}, true
	case Web_Pair:
		if !state.settings.web_access do return fail("turn on Web access first (Settings › Machines › Web access)"), false
		now := time.to_unix_seconds(time.now())
		code, until := web_code_open(now)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"code":`)
		json_quote(&b, web_code_shown(code))
		fmt.sbprintf(&b, `,"expires_in":%d,"until":%d,"address":`, until - now, until)
		json_quote(&b, web_listen_address())
		strings.write_byte(&b, '}')
		window_state_changed() // live.web.pairing
		return {ok = true, data = strings.to_string(b)}, false
	case Web_Devices:
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"devices":[`)
		for d, i in web_live(context.temp_allocator).devices {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, `{"id":`)
			json_quote(&b, d.id)
			strings.write_string(&b, `,"name":`)
			json_quote(&b, d.name)
			fmt.sbprintf(&b, `,"paired":%d,"last_seen":%d,"linked":%v}}`, d.paired, d.last_seen, d.linked)
		}
		strings.write_string(&b, "]}")
		return {ok = true, data = strings.to_string(b)}, false
	case Web_Revoke:
		found := false
		{
			sync.guard(&web.mu)
			web_load_locked()
			for &d, i in web.devices do if d.id == c.id {
				web_device_free(&d)
				ordered_remove(&web.devices, i)
				web.dirty = true
				found = true
				break
			}
		}
		if !found do return fail("no paired browser with that id"), false
		window_link_web_revoked(c.id) // its live link closes
		web_save()
		window_state_changed()
		return {ok = true}, false
	}
	return fail("not a web command"), false
}

// What Settings shows (core_live.odin; also web_devices). Strings in allocator.
web_live :: proc(a: runtime.Allocator) -> (l: Web_Live) {
	linked := window_link_web_device()
	sync.guard(&web.mu)
	web_load_locked()
	l.listening = web.fd > 0 && web.bound != ""
	l.address = strings.clone(web.bound, a)
	l.error = strings.clone(web.error, a)
	if web.code.until > 0 && web.code.tries < WEB_CODE_TRIES do l.pairing = web.code.until
	l.devices = make([]Web_Device_Live, len(web.devices), a)
	for d, i in web.devices do l.devices[i] = {id = strings.clone(d.id, a), name = strings.clone(d.name, a), paired = d.paired, last_seen = d.last_seen, linked = d.id == linked}
	return
}

// ---- the main thread's turn (serve's loop) ----

// Starts, moves or stops the listener as the settings say; saves the devices; closes the links of
// browsers forgotten over HTTP; sweeps expired tokens hourly.
web_tick :: proc() {
	want := state.settings.web_access && core_separate
	addr := web_listen_address()
	if !want {
		if web.bound != "" || web.error != "" do web_listen_stop()
		if window_link_web_device() != "" do window_link_web_close("Web access was turned off")
		sync.lock(&web.mu)
		web.code = {}
		sync.unlock(&web.mu)
	} else if web.bound != addr {
		retry := web.failed != addr || time.tick_since(web.failed_at) >= WEB_RETRY
		if retry {
			web_listen_stop()
			web_listen_start(addr)
		}
	}
	kicked: [dynamic]string
	{
		sync.guard(&web.mu)
		kicked, web.kick = web.kick, nil
		if web.expired_at == {} || time.tick_since(web.expired_at) >= time.Hour {
			web.expired_at = time.tick_now()
			if web_expire_locked(time.to_unix_seconds(time.now())) do web.dirty = true
		}
	}
	for id in kicked {
		window_link_web_revoked(id)
		delete(id, runtime.heap_allocator())
	}
	delete(kicked)
	web_save()
}

// The core stops (serve_stop): the listener goes.
web_stop :: proc() {
	web_listen_stop()
	web_save()
}

@(private = "file")
web_set_str :: proc(s: ^string, v: string) {
	heap := runtime.heap_allocator()
	delete(s^, heap)
	s^ = strings.clone(v, heap)
}

@(private = "file")
web_listen_start :: proc(addr: string) {
	fd, why := web_tcp_listen(addr)
	sync.lock(&web.mu)
	if fd < 0 {
		web_set_str(&web.error, why)
		web_set_str(&web.failed, addr)
		web.failed_at = time.tick_now()
		sync.unlock(&web.mu)
		log_fln("Deckhand: web access cannot listen on %s: %s", addr, why)
		window_state_changed()
		return
	}
	web.fd = fd
	web_set_str(&web.bound, addr)
	web_set_str(&web.error, "")
	web_set_str(&web.failed, "")
	epoch := sync.atomic_load(&web.epoch)
	sync.unlock(&web.mu)
	web.accept = thread.create_and_start_with_poly_data2(fd, epoch, web_accept_loop)
	log_fln("Deckhand: web access listens on %s (plain HTTP)", addr)
	window_state_changed()
}

@(private = "file")
web_listen_stop :: proc() {
	sync.atomic_add(&web.epoch, 1) // connections and relays of the old listener end
	if web.accept != nil {
		thread.join(web.accept)
		thread.destroy(web.accept)
		web.accept = nil
	}
	sync.lock(&web.mu)
	if web.fd > 0 do posix.close(web.fd)
	web.fd = 0
	was := web.bound != ""
	web_set_str(&web.bound, "")
	web_set_str(&web.error, "")
	sync.unlock(&web.mu)
	if was do log_ln("Deckhand: web access stopped listening")
	window_state_changed()
}

// The listener's port as bound (tests bind port 0). 0: none.
web_bound_port :: proc() -> int {
	sync.guard(&web.mu)
	if web.fd <= 0 do return 0
	ss: posix.sockaddr_storage
	n := posix.socklen_t(size_of(ss))
	if posix.getsockname(web.fd, (^posix.sockaddr)(&ss), &n) != .OK do return 0
	if ss.ss_family == .INET6 do return int((^posix.sockaddr_in6)(&ss).sin6_port)
	return int((^posix.sockaddr_in)(&ss).sin_port)
}

when TEST_HOOKS {
	// Tests: the devices and the code back to nothing (nothing read from disk).
	web_reset_for_test :: proc() {
		sync.guard(&web.mu)
		for &d in web.devices do web_device_free(&d)
		clear(&web.devices)
		web.loaded = true
		web.dirty = false
		web.code = {}
		for k in web.kick do delete(k, runtime.heap_allocator())
		clear(&web.kick)
	}
	web_device_count_for_test :: proc() -> int {
		sync.guard(&web.mu)
		return len(web.devices)
	}
	web_code_for_test :: proc() -> string {
		sync.guard(&web.mu)
		return strings.clone(string(web.code.code[:]), context.temp_allocator)
	}
	web_age_for_test :: proc(seconds: i64) {
		sync.guard(&web.mu)
		for &d in web.devices do d.paired, d.last_seen = d.paired - seconds, d.last_seen - seconds
		web.code.until -= seconds
	}
}
