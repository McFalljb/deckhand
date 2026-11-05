package fake_app

// A stand-in for an engine in a pi-desk app tab (docs/ENGINE-BRIDGE.md §7,
// step 1 part): the NDJSON hello on PI_DESK_SOCKET, the Mach frame channel
// (src/native/frames_macos.m's connect half), a 60 Hz loop that draws a
// moving square with Metal into the ring and sends FRAME from the empty
// command buffer's completed handler. Answers tab.ping, tab.visible and
// tab.quit; logs every input message it gets to stdout ("input: …"), which
// pi-desk keeps in the tab's log.
//
// Its own methods (engine bridge step 2: app_call passes any method through;
// tab.describe lists them): game.get {path: "square"|"tick"}, game.set
// {path: "square", value: {x, y}|null} (null: it moves again). It sends
// tab.boxes ({id, label, rect} in logical px) whenever they change.
//
// World (logical px): the square, 40x40 at x = 20 + (tick*2) mod (w-60),
// y = 40, #FF4040; a wall at 20,120 200x20 #40A040; a coin at 300,200 16x16
// #F0D020; background #202830.
//
// Flags:
//   --crash-after N   abort() after N frames
//   --hang-after N    after N frames stop reading everything (socket, Mach) and drawing
//   --freeze-after N  after N frames stop drawing, but keep answering (a busy engine)
//   --exit N          exit with code N right after the hello
//   --once FILE       --crash-after/--hang-after/--exit only when FILE does not exist (it is created)
//   --bad-key         send a wrong key in HELLO
//   --no-frames       never connect the Mach channel
//   --slow-ms N       delay each commit by N ms

import "base:runtime"
import "core:c"
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

foreign import native {"../../build/pd_frames.a", "../../build/fake_render.a", "system:Metal.framework", "system:IOSurface.framework", "system:Foundation.framework", "system:bsm"}

Conn :: distinct rawptr
Box :: struct {
	x, y, w, h: c.int,
	rgb:        u32,
}

@(default_calling_convention = "c")
foreign native {
	pd_frames_connect :: proc(service: cstring, key: [^]u8, tab_id: u64, device: rawptr, err: [^]u8, errcap: c.int) -> Conn ---
	pd_frames_acquire :: proc(cn: Conn, gen: ^u32, slot: ^c.int, w, h: ^c.int, scale: ^f32, texture: ^rawptr) -> c.int ---
	pd_frames_unacquire :: proc(cn: Conn, slot: c.int) ---
	pd_frames_present :: proc(cn: Conn, gen: u32, slot: c.int, seq, tick: u64, queue: rawptr) ---
	pd_frames_conn_suspend :: proc(cn: Conn, on: c.int) ---
	pd_frames_conn_dead :: proc(cn: Conn) -> c.int ---
	pd_frames_conn_stats :: proc(cn: Conn, sent, dropped, rings: ^u64, gen: ^u32, w, h: ^c.int) ---
	pd_frames_device_for :: proc(registry_id: u64) -> rawptr ---
	fake_queue :: proc(device: rawptr) -> rawptr ---
	fake_render :: proc(queue, texture: rawptr, w, h: c.int, bg: u32, boxes: [^]Box, n: c.int, slow_ms: c.int) ---
}

Flags :: struct {
	crash_after, hang_after, freeze_after, exit_code, slow_ms: int,
	once:                                        string,
	bad_key, no_frames:                          bool,
}

flags: Flags
sock: posix.FD = -1
write_mu: sync.Mutex
visible := true // tab.visible (atomic)
quitting: bool // tab.quit (atomic)
hung: bool // --hang-after reached (atomic)
// game state the reader sets and the loop reads (atomic)
sq_fixed: bool // game.set square: it stays at sq_x, sq_y
sq_x, sq_y: int
cur_tick: u64

ok_reply :: proc(id, data: string) {
	send_line(fmt.tprintf(`{{"id":"%s","v":1,"type":"result","result":{{"ok":true,"data":%s}}}}`, id, data))
}

square_json :: proc() -> string {
	return fmt.tprintf(`{{"x":%d,"y":%d,"w":40,"h":40,"moving":%v}}`, sync.atomic_load(&sq_x), sync.atomic_load(&sq_y), !sync.atomic_load(&sq_fixed))
}

say :: proc(args: ..any) {
	fmt.println(..args)
	os.flush(os.stdout)
}

send_line :: proc(line: string) {
	sync.lock(&write_mu)
	defer sync.unlock(&write_mu)
	b := transmute([]u8)strings.concatenate({line, "\n"}, context.temp_allocator)
	for len(b) > 0 {
		n := posix.send(sock, raw_data(b), uint(len(b)), {})
		if n <= 0 do return
		b = b[n:]
	}
}

// One line from the socket (blocking); "" at EOF.
read_buf: [dynamic]u8
read_line :: proc() -> (string, bool) {
	for {
		if i := strings.index_byte(string(read_buf[:]), '\n'); i >= 0 {
			line := strings.clone(string(read_buf[:i]), context.temp_allocator)
			remove_range(&read_buf, 0, i + 1)
			return line, true
		}
		chunk: [4096]u8
		n := posix.recv(sock, raw_data(chunk[:]), len(chunk), {})
		if n <= 0 do return "", false
		append(&read_buf, ..chunk[:n])
	}
}

// --once FILE: true when the fault should happen this run (and marks it done).
fault_now :: proc() -> bool {
	if flags.once == "" do return true
	if os.exists(flags.once) do return false
	_ = os.write_entire_file(flags.once, transmute([]u8)string("1"))
	return true
}

reader :: proc() {
	for {
		if sync.atomic_load(&hung) {
			for {time.sleep(time.Second)} // stops reading everything
		}
		free_all(context.temp_allocator)
		line, ok := read_line()
		if !ok {
			say("socket closed: exiting")
			os.exit(0)
		}
		if sync.atomic_load(&hung) do continue // hung while waiting: this one is not read either
		v, err := json.parse_string(line, .JSON, true, context.temp_allocator)
		if err != nil do continue
		obj, _ := v.(json.Object)
		type, _ := obj["type"].(json.String)
		id, _ := obj["id"].(json.String)
		switch type {
		case "input":
			say("input:", line)
		case "tab.ping":
			send_line(fmt.tprintf(`{{"id":"%s","v":1,"type":"result","result":{{"ok":true,"data":{{}}}}}}`, id))
		case "tab.visible":
			vis, _ := obj["visible"].(json.Boolean)
			sync.atomic_store(&visible, bool(vis))
			say("visible:", vis)
			send_line(fmt.tprintf(`{{"id":"%s","v":1,"type":"result","result":{{"ok":true,"data":{{}}}}}}`, id))
		case "tab.quit":
			send_line(fmt.tprintf(`{{"id":"%s","v":1,"type":"result","result":{{"ok":true,"data":{{}}}}}}`, id))
			say("quit requested")
			sync.atomic_store(&quitting, true)
		case "tab.describe":
			ok_reply(id, `{"name":"fake","methods":[{"name":"game.get","params":{"path":"square|tick"}},{"name":"game.set","params":{"path":"square","value":"{x, y} or null"}}],"events":["tab.log","tab.boxes"]}`)
		case "game.get":
			path, _ := obj["path"].(json.String)
			switch path {
			case "square": ok_reply(id, fmt.tprintf(`{{"value":%s}}`, square_json()))
			case "tick":   ok_reply(id, fmt.tprintf(`{{"value":%d}}`, sync.atomic_load(&cur_tick)))
			case:
				send_line(fmt.tprintf(`{{"id":"%s","v":1,"type":"result","result":{{"ok":false,"error":"no such path","code":"no_path","path":%q,"at":"game"}}}}`, id, path))
			}
		case "game.set":
			path, _ := obj["path"].(json.String)
			if path != "square" {
				send_line(fmt.tprintf(`{{"id":"%s","v":1,"type":"result","result":{{"ok":false,"error":"no such path","code":"no_path","path":%q}}}}`, id, path))
				continue
			}
			if val, is := obj["value"].(json.Object); is {
				num :: proc(v: json.Value) -> int {
					#partial switch n in v {
					case json.Integer: return int(n)
					case json.Float:   return int(n)
					}
					return 0
				}
				sync.atomic_store(&sq_x, num(val["x"]))
				sync.atomic_store(&sq_y, num(val["y"]))
				sync.atomic_store(&sq_fixed, true)
			} else do sync.atomic_store(&sq_fixed, false)
			say("game.set square:", square_json())
			ok_reply(id, fmt.tprintf(`{{"value":%s}}`, square_json()))
		case:
			if id != "" { // any other method: an answer, never silence
				send_line(fmt.tprintf(`{{"id":"%s","v":1,"type":"result","result":{{"ok":false,"error":"not supported by the fake app","code":"not_supported","method":%q}}}}`, id, type))
			}
		}
	}
}

int_arg :: proc(args: []string, i: ^int) -> int {
	i^ += 1
	if i^ >= len(args) do return 0
	n, _ := strconv.parse_int(args[i^])
	return n
}

main :: proc() {
	args := os.args
	for i := 1; i < len(args); i += 1 {
		switch args[i] {
		case "--crash-after": flags.crash_after = int_arg(args, &i)
		case "--hang-after":  flags.hang_after = int_arg(args, &i)
		case "--freeze-after": flags.freeze_after = int_arg(args, &i)
		case "--exit":        flags.exit_code = int_arg(args, &i)
		case "--slow-ms":     flags.slow_ms = int_arg(args, &i)
		case "--bad-key":     flags.bad_key = true
		case "--no-frames":   flags.no_frames = true
		case "--once":
			i += 1
			if i < len(args) do flags.once = args[i]
		case:
			say("unknown flag", args[i])
			os.exit(2)
		}
	}
	path := os.get_env("PI_DESK_SOCKET", context.temp_allocator)
	token := os.get_env("PI_DESK_TOKEN", context.temp_allocator)
	if path == "" || token == "" {
		say("fake-app: needs PI_DESK_SOCKET and PI_DESK_TOKEN (run it from a pi-desk app tab)")
		os.exit(2)
	}
	say(fmt.tprintf("fake-app %d: pgid %d sid %d", posix.getpid(), posix.getpgrp(), posix.getsid(0)))
	sock = posix.socket(.UNIX, .STREAM)
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	for i in 0 ..< min(len(path), len(addr.sun_path) - 1) do addr.sun_path[i] = c.char(path[i])
	addr.sun_len = u8(size_of(addr))
	if posix.connect(sock, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		say("fake-app: cannot connect to", path)
		os.exit(1)
	}
	send_line(fmt.tprintf(`{{"id":"1","v":1,"type":"hello","token":"%s","app":"fake","pid":%d}}`, token, posix.getpid()))
	line, ok := read_line()
	if !ok {
		say("fake-app: no hello reply")
		os.exit(1)
	}
	v, _ := json.parse_string(line, .JSON, true)
	// pi-desk sends nothing before the hello reply (docs/PROTOCOL.md §2)
	first, _ := v.(json.Object)
	first_id, _ := first["id"].(json.String)
	first_type, _ := first["type"].(json.String)
	if first_id != "1" || first_type != "result" {
		say("fake-app: a line before the hello reply:", line)
		os.exit(1)
	}
	res, _ := v.(json.Object)["result"].(json.Object)
	data, _ := res["data"].(json.Object)
	if okv, _ := res["ok"].(json.Boolean); !okv {
		say("fake-app: hello refused:", line)
		os.exit(1)
	}
	tab_id := u64(data["tab_id"].(json.Integer) or_else 0)
	fr, _ := data["frames"].(json.Object)
	service, _ := fr["service"].(json.String)
	key_hex, _ := fr["key"].(json.String)
	device_id := u64(fr["device"].(json.Integer) or_else 0)
	say(fmt.tprintf("hello ok: tab %d, service %s, device %d", tab_id, service, device_id)) // never the key
	if flags.exit_code != 0 && fault_now() {
		say("exiting with", flags.exit_code)
		os.exit(flags.exit_code)
	}
	thread.create_and_start(reader)
	if flags.no_frames || service == "" {
		for !sync.atomic_load(&quitting) do time.sleep(50 * time.Millisecond)
		os.exit(0)
	}
	key, kok := hex.decode(transmute([]u8)key_hex)
	if !kok || len(key) != 32 {
		say("fake-app: bad key in the hello reply")
		os.exit(1)
	}
	if flags.bad_key do key[0] ~= 0xFF
	device := pd_frames_device_for(device_id)
	queue := fake_queue(device)
	errbuf: [256]u8
	cn := pd_frames_connect(strings.clone_to_cstring(service), raw_data(key), tab_id, device, &errbuf[0], len(errbuf))
	if cn == nil {
		say("fake-app: frames:", string(cstring(&errbuf[0])))
		os.exit(1)
	}
	tick, seq, frames: u64
	last_boxes := ""
	next := time.tick_now()
	last_log := time.tick_now()
	crash_due := flags.crash_after > 0 && fault_now()
	hang_due := flags.hang_after > 0 && fault_now()
	for {
		free_all(context.temp_allocator)
		if sync.atomic_load(&quitting) do os.exit(0)
		if pd_frames_conn_dead(cn) != 0 {
			say("pi-desk is gone: exiting")
			os.exit(0)
		}
		tick += 1
		sync.atomic_store(&cur_tick, tick)
		frozen := flags.freeze_after > 0 && frames >= u64(flags.freeze_after)
		if sync.atomic_load(&visible) && !frozen {
			gen: u32
			slot, w, h: c.int
			scale: f32
			tex: rawptr
			if pd_frames_acquire(cn, &gen, &slot, &w, &h, &scale, &tex) != 0 {
				lw := int(f32(w) / scale)
				sx, sy := 20 + int(tick * 2) % max(lw - 60, 1), 40
				if sync.atomic_load(&sq_fixed) do sx, sy = sync.atomic_load(&sq_x), sync.atomic_load(&sq_y)
				else {
					sync.atomic_store(&sq_x, sx)
					sync.atomic_store(&sq_y, sy)
				}
				s := scale
				boxes := [3]Box {
					{c.int(f32(20) * s), c.int(f32(120) * s), c.int(f32(200) * s), c.int(f32(20) * s), 0x40A040},
					{c.int(f32(300) * s), c.int(f32(200) * s), c.int(f32(16) * s), c.int(f32(16) * s), 0xF0D020},
					{c.int(f32(sx) * s), c.int(f32(sy) * s), c.int(f32(40) * s), c.int(f32(40) * s), 0xFF4040},
				}
				// its boxes (logical px), when they change: the square is listed last (on top)
				bx := fmt.tprintf(`{{"v":1,"type":"event","event":"tab.boxes","boxes":[{{"id":"e:2:1","label":"wall","rect":{{"x":20,"y":120,"w":200,"h":20}}}},{{"id":"e:3:1","label":"coin","rect":{{"x":300,"y":200,"w":16,"h":16}}}},{{"id":"e:1:1","label":"square","rect":{{"x":%d,"y":%d,"w":40,"h":40}}}}]}}`, sx, sy)
				if bx != last_boxes {
					send_line(bx)
					delete(last_boxes)
					last_boxes = strings.clone(bx)
				}
				fake_render(queue, tex, w, h, 0x202830, &boxes[0], len(boxes), c.int(flags.slow_ms))
				seq += 1
				pd_frames_present(cn, gen, slot, seq, tick, queue)
				frames += 1
			}
		}
		if crash_due && frames >= u64(flags.crash_after) {
			say("crashing after", frames, "frames")
			posix.abort()
		}
		if hang_due && frames >= u64(flags.hang_after) {
			say("hanging after", frames, "frames")
			sync.atomic_store(&hung, true)
			pd_frames_conn_suspend(cn, 1)
			for {time.sleep(time.Second)}
		}
		if time.tick_since(last_log) > time.Second {
			last_log = time.tick_now()
			sent, dropped, rings: u64
			gen: u32
			w, h: c.int
			pd_frames_conn_stats(cn, &sent, &dropped, &rings, &gen, &w, &h)
			say(fmt.tprintf("stats: tick %d, frames sent %d, dropped %d, rings %d, gen %d, %dx%d", tick, sent, dropped, rings, gen, w, h))
			send_line(fmt.tprintf(`{{"v":1,"type":"event","event":"tab.log","level":"info","text":"tick %d, %d frames","tick":%d}}`, tick, sent, tick))
		}
		next = time.tick_add(next, time.Second / 60)
		if d := time.tick_diff(time.tick_now(), next); d > 0 do time.sleep(d)
		else do next = time.tick_now()
	}
}

_ :: runtime
