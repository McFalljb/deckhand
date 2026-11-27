package core

// Codex's usage (usage.odin; docs/CODEX.md §6b): Codex's own documented app-server reads it. For
// an account Deckhand runs `codex app-server` (stdio, JSON lines) with that account's CODEX_HOME,
// as its tabs get it (set after the login profile; nothing for the default home), through the
// login shell as a tab's codex is found, and says:
//
//   {"id":1,"method":"initialize","params":{"clientInfo":{"name":"deckhand",…}}}
//   {"method":"initialized"}
//   {"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}
//
// then closes stdin and stops it (its process group; USAGE_READ_TIMEOUT at most). Codex fetches
// the numbers with its own sign-in: Deckhand never opens auth.json nor calls any endpoint. The
// answer (GetAccountRateLimitsResponse, marked experimental) is read loosely: unknown fields are
// ignored, a missing one is "not said". Only Codex's own words (its app-server's account
// processor, 0.169) make an error answer a state: "chatgpt authentication required to read rate
// limits" is an API-key account (no plan limits), "codex account authentication required to read
// rate limits" signed out; any other is an error (the last good numbers kept). initialize must
// answer, and for any home but Codex's default its codexHome must be the home asked for (missing:
// the read fails, "can't confirm which account"), else the answer is not used.
//
// Test mode runs DECKHAND_CODEX_CMD (tests/scripts/fake-codex.py's app-server mode), never a
// real codex (codex_tab_cmd); unit tests start nothing unless one asks (usage.odin).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import jg "../jsonguard"

USAGE_READ_TIMEOUT :: 30 * time.Second // the login shell, codex's start, its fetch
USAGE_REPLY_MAX :: 256 << 10 // bytes of output the whole run may write (more: it is stopped)

// The shell line that runs `codex app-server` for an account's home ("" = none). Temp.
usage_codex_script :: proc(home: string) -> string {
	account := home == codex_home() ? "" : home
	if account != "" && !claude_account_known(account, .Codex) do return ""
	set := ""
	for e in claude_account_env(account, .Codex) do if strings.has_prefix(e, "DECKHAND_CODEX_ACCOUNT=") {
		set = strings.concatenate({"DECKHAND_CODEX_ACCOUNT=", sh_quote(e[len("DECKHAND_CODEX_ACCOUNT="):]), "; "}, context.temp_allocator)
	}
	return strings.clone(strings.concatenate({"set -- app-server; ", set, CODEX_ACCOUNT_SH, codex_tab_cmd(harness_path(.Codex))}, context.temp_allocator))
}

// The JSON lines Deckhand sends (tests read them too).
usage_codex_requests :: proc() -> (init, initialized, read: string) {
	init = fmt.tprintf(`{{"id":1,"method":"initialize","params":{{"clientInfo":{{"name":"deckhand","title":"Deckhand","version":"%s"}}}}}}`, core_version() != "" ? core_version() : "dev")
	initialized = `{"method":"initialized"}`
	read = `{"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}`
	return
}

// Runs the exchange and parses its answer (heap; any thread).
usage_codex_read :: proc(script, home: string, default_home := false) -> ^Usage_Read {
	init_reply, read_reply, why := usage_codex_exchange(script)
	if why != "" {
		r := new(Usage_Read, runtime.heap_allocator())
		r.status = .Error
		r.error = strings.clone(why, runtime.heap_allocator())
		return r
	}
	return usage_codex_parse(init_reply, read_reply, home, default_home)
}

// The app-server conversation: the replies to requests 1 and 2 (their JSON lines), or why not.
@(private = "file")
usage_codex_exchange :: proc(script: string) -> (init_reply, read_reply: string, why: string) {
	Talk :: struct {
		init_reply, read_reply: string,
		sent_read:              bool,
	}
	talk: Talk
	init, _, _ := usage_codex_requests()
	why = usage_exchange(script, {prog = "codex", what = "codex app-server", none = "codex app-server ended without an answer (is Codex installed and new enough?)"}, init, &talk, proc(data: rawptr, line: string) -> (st: Usage_Step) {
		t := (^Talk)(data)
		// a reply by its id; anything else (a notification, a profile's output) is skipped
		id, has := usage_reply_id(line)
		if !has do return
		if id == 1 && t.init_reply == "" {
			t.init_reply = line
			_, initialized, read := usage_codex_requests()
			st.send = make([]string, 2, context.temp_allocator) // outlives this step: never a literal's stack
			st.send[0], st.send[1] = initialized, read
			st.answered = true
			t.sent_read = true
		} else if id == 2 && t.sent_read {
			t.read_reply = line
			st.done = true
		}
		return
	})
	return talk.init_reply, talk.read_reply, why
}

// What a usage exchange's process is called in its errors.
Usage_Prog :: struct {
	prog: string, // what could not start: "codex"
	what: string, // what did not answer: "codex app-server"
	none: string, // it ended before any answer
}

// One step of an exchange: the lines to send now, whether the answer is complete, or why it
// failed; answered: a first answer came (an end after it "ended before it answered").
Usage_Step :: struct {
	send:     []string,
	done:     bool,
	fail:     string,
	answered: bool,
}

// A usage read's process (both sources): the script through the login shell, in `/`, stderr to
// /dev/null, in a process group of its own; first sent, then each whole line of its output goes
// to step until it says done (or fails). Then stdin is closed and it ends on its own (its output
// read to the end, so none of its group still holds it), else its group is stopped (SIGTERM after
// 0.5 s, SIGKILL after the grace). At most USAGE_READ_TIMEOUT and USAGE_REPLY_MAX of output for
// the whole run. "" = done; else why not.
usage_exchange :: proc(script: string, names: Usage_Prog, first: string, data: rawptr, step: proc(data: rawptr, line: string) -> Usage_Step) -> (why: string) {
	argv := shell_script_argv(login_shell(), script, names.prog)
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	no_start := fmt.tprintf("could not start %s", names.prog)
	pin, pout: [2]posix.FD
	if posix.pipe(&pin) != .OK do return no_start
	if posix.pipe(&pout) != .OK {
		posix.close(pin[0])
		posix.close(pin[1])
		return no_start
	}
	for fd in ([4]posix.FD{pin[0], pin[1], pout[0], pout[1]}) do posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))
	null_fd := posix.open("/dev/null", {.RDWR, .CLOEXEC})
	defer if null_fd >= 0 do posix.close(null_fd)
	attr, fa: [512]u8
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	posix_spawnattr_setflags(&attr, i16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
	posix_spawnattr_setpgroup(&attr, 0)
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	posix_spawn_file_actions_adddup2(&fa, i32(pin[0]), 0)
	posix_spawn_file_actions_adddup2(&fa, i32(pout[1]), 1)
	posix_spawn_file_actions_adddup2(&fa, i32(null_fd), 2)
	posix_spawn_file_actions_addchdir_np(&fa, "/") // no project's folder: it reads none
	pid: posix.pid_t
	sync.rw_mutex_shared_lock(&fork_lock)
	err := posix.posix_spawnp(&pid, cargv[0], &fa, &attr, raw_data(cargv), posix.environ)
	sync.rw_mutex_shared_unlock(&fork_lock)
	posix.close(pin[0])
	posix.close(pout[1])
	if err != .NONE {
		posix.close(pin[1])
		posix.close(pout[0])
		return no_start
	}
	// a process gone mid-write: an error, not SIGPIPE (the serve process ignores it anyway; a
	// window's in-process core may not)
	when ODIN_OS == .Darwin {
		F_SETNOSIGPIPE :: 73
		posix.fcntl(pin[1], posix.FCNTL_Cmd(F_SETNOSIGPIPE), i32(1))
	}
	send :: proc(fd: posix.FD, line: string) -> bool {
		msg := strings.concatenate({line, "\n"}, context.temp_allocator)
		return posix.write(fd, raw_data(msg), uint(len(msg))) == len(msg)
	}
	if !send(pin[1], first) do why = fmt.tprintf("%s did not start", names.what)
	deadline := time.tick_now()._nsec + i64(USAGE_READ_TIMEOUT)
	buf := make([dynamic]u8, 0, 4096, context.temp_allocator)
	chunk: [16 << 10]u8
	open := why == ""
	done := false
	answered := false
	total := 0 // bytes read, the whole run
	eof := false // its stdout ended (every writer closed it)
	for open {
		// each whole line to step
		for {
			nl := -1
			for c, i in buf do if c == '\n' {
				nl = i
				break
			}
			if nl < 0 do break
			line := strings.clone(strings.trim_space(string(buf[:nl])), context.temp_allocator)
			remove_range(&buf, 0, nl + 1)
			st := step(data, line)
			answered ||= st.answered
			if st.fail != "" {
				why = st.fail
				open = false
				break
			}
			for l in st.send do if !send(pin[1], l) {
				why = fmt.tprintf("%s stopped", names.what)
				open = false
				break
			}
			if !open do break
			if st.done {
				done = true
				open = false
				break
			}
		}
		if !open do break
		left := deadline - time.tick_now()._nsec
		if left <= 0 {
			why = fmt.tprintf("%s did not answer in time", names.what)
			break
		}
		pfd := [1]posix.pollfd{{fd = pout[0], events = {.IN}}}
		if posix.poll(&pfd[0], 1, i32(min(left / 1e6, 200))) <= 0 do continue
		n := posix.read(pout[0], &chunk[0], len(chunk))
		if n <= 0 {
			eof = n == 0
			why = answered ? fmt.tprintf("%s ended before it answered", names.what) : names.none
			break
		}
		total += int(n)
		if total > USAGE_REPLY_MAX {
			why = fmt.tprintf("%s's output was too long", names.what)
			break
		}
		append(&buf, ..chunk[:n])
	}
	// done: stdin closed (the process's end); it ends on its own (its output read to the end, so
	// none of its group still holds it), else its group is stopped
	posix.close(pin[1])
	wstatus: i32
	exited := false
	clean := why == "" // it answered: give it the grace to end by itself
	grace := time.tick_now()._nsec + i64(500 * time.Millisecond)
	for clean && !(exited && eof) && time.tick_now()._nsec < grace {
		if !exited && posix.waitpid(pid, &wstatus, {.NOHANG}) == pid do exited = true
		if !eof {
			pfd := [1]posix.pollfd{{fd = pout[0], events = {.IN}}}
			if posix.poll(&pfd[0], 1, 20) > 0 {
				n := posix.read(pout[0], &chunk[0], len(chunk))
				if n <= 0 do eof = true // the rest is dropped
			}
		} else if !exited do time.sleep(20 * time.Millisecond)
	}
	posix.close(pout[0])
	if !exited {
		posix.killpg(pid, .SIGTERM)
		grace = time.tick_now()._nsec + i64(changes_kill_grace)
		for !exited && time.tick_now()._nsec < grace {
			if posix.waitpid(pid, &wstatus, {.NOHANG}) == pid do exited = true
			else do time.sleep(20 * time.Millisecond)
		}
	}
	// the rest of its group, unless it ended by itself and its output was closed by all: then the
	// group is gone and its id may be another's by now
	if !(exited && eof) do posix.killpg(pid, .SIGKILL)
	if !exited do posix.waitpid(pid, &wstatus, {})
	if !done && why == "" do why = fmt.tprintf("%s gave no answer", names.what)
	return
}

// A JSON-RPC reply's id (a response or an error to one of ours), from one line.
@(private = "file")
usage_reply_id :: proc(line: string) -> (id: i64, ok: bool) {
	if !strings.has_prefix(line, "{") do return 0, false
	v, err := jg.parse_string(line, .JSON, true, context.temp_allocator)
	if err != nil do return 0, false
	o, is := v.(json.Object)
	if !is do return 0, false
	if _, req := o["method"]; req do return 0, false // a notification or the server's own request
	#partial switch x in o["id"] {
	case json.Integer: return i64(x), true
	case json.Float:   return i64(x), true
	}
	return 0, false
}

// The replies' meaning (heap). Pure but for the hash; tests feed it the schema's examples.
usage_codex_parse :: proc(init_reply, read_reply, home: string, default_home := false) -> ^Usage_Read {
	heap := runtime.heap_allocator()
	r := new(Usage_Read, heap)
	r.windows = make([dynamic]Usage_Window, heap)
	fail :: proc(r: ^Usage_Read, why: string) -> ^Usage_Read {
		r.status = .Error
		r.error = strings.clone(cut_utf8(usage_strip_emails(one_line(why, context.temp_allocator)), USAGE_ERROR_MAX), runtime.heap_allocator())
		return r
	}
	// initialize answered, and for any home but the default its codexHome is the home asked for (a
	// profile that moved CODEX_HOME, or a Codex that does not say: maybe another account's numbers)
	{
		iv, err := jg.parse_string(init_reply, .JSON, true, context.temp_allocator)
		if err != nil do return fail(r, "Codex's initialize answer was not JSON")
		io, _ := iv.(json.Object)
		if _, has := io["error"]; has do return fail(r, "Codex refused to initialize")
		res, is := io["result"].(json.Object)
		if !is do return fail(r, "Codex's initialize answer had no result")
		got, has := res["codexHome"].(json.String)
		if !has || got == "" {
			if !default_home do return fail(r, "can't confirm which account Codex read")
		} else if home != "" {
			g, h := strings.trim_right(string(got), "/"), strings.trim_right(home, "/")
			rg, rh := fs_real(g), fs_real(h)
			if g != h && (rg == "" || rg != rh) do return fail(r, "Codex answered for another home")
		}
	}
	v, err := jg.parse_string(read_reply, .JSON, true, context.temp_allocator)
	if err != nil do return fail(r, "Codex's answer was not JSON")
	o, _ := v.(json.Object)
	if e, is := o["error"].(json.Object); is {
		msg := string(e["message"].(json.String) or_else "")
		switch strings.to_lower(strings.trim_space(msg), context.temp_allocator) {
		case "chatgpt authentication required to read rate limits":
			r.status = .No_Limits
			return r
		case "codex account authentication required to read rate limits":
			r.status = .Signed_Out
			return r
		}
		return fail(r, msg != "" ? msg : "Codex refused the request")
	}
	res, is := o["result"].(json.Object)
	if !is do return fail(r, "Codex's answer had no result")
	main_limit, _ := res["rateLimits"].(json.Object)
	str :: proc(o: json.Object, k: string) -> string {return string(o[k].(json.String) or_else "")}
	num :: proc(o: json.Object, k: string) -> (f64, bool) {
		#partial switch x in o[k] {
		case json.Integer: return f64(x), true
		case json.Float:   return f64(x), true
		}
		return 0, false
	}
	window :: proc(r: ^Usage_Read, o: json.Object, name: string) {
		if o == nil || len(r.windows) >= USAGE_WINDOWS_MAX do return
		w := Usage_Window{used_percent = -1}
		if p, ok := num(o, "usedPercent"); ok do w.used_percent = usage_clamp_percent(p)
		if m, ok := num(o, "windowDurationMins"); ok && m > 0 && m <= 366 * 24 * 60 do w.window_mins = i64(m)
		if t, ok := num(o, "resetsAt"); ok && t > 0 && t < 32503680000 do w.resets_at = i64(t) // before the year 3000
		w.name = strings.clone(cut_utf8(one_line(name, context.temp_allocator), USAGE_TEXT_MAX), runtime.heap_allocator())
		append(&r.windows, w)
	}
	snapshot :: proc(r: ^Usage_Read, s: json.Object, name: string) {
		p, _ := s["primary"].(json.Object)
		window(r, p, name)
		q, _ := s["secondary"].(json.Object)
		window(r, q, name)
	}
	if main_limit != nil {
		snapshot(r, main_limit, "")
		r.plan = strings.clone(cut_utf8(str(main_limit, "planType"), USAGE_TEXT_MAX), heap)
		if t := str(main_limit, "rateLimitReachedType"); t != "" do r.limit_hit = true
		if c, has := main_limit["credits"].(json.Object); has {
			credits := ""
			switch {
			case bool(c["unlimited"].(json.Boolean) or_else false): credits = "unlimited"
			case str(c, "balance") != "":                           credits = str(c, "balance")
			case !bool(c["hasCredits"].(json.Boolean) or_else true): credits = "none"
			}
			r.credits = strings.clone(cut_utf8(one_line(credits, context.temp_allocator), USAGE_TEXT_MAX), heap)
		}
	}
	// other buckets (a model's own limits): their windows, named, for the hover
	if by, has := res["rateLimitsByLimitId"].(json.Object); has {
		main_id := main_limit != nil ? str(main_limit, "limitId") : ""
		if main_id == "" do main_id = "codex"
		keys := make([dynamic]string, context.temp_allocator)
		for k in by do append(&keys, k)
		sort_strings(keys[:])
		for k in keys {
			if k == main_id do continue
			s, _ := by[k].(json.Object)
			if s == nil do continue
			name := str(s, "limitName")
			snapshot(r, s, name != "" ? name : k)
		}
	}
	if id := str(res, "accountId"); id != "" do r.hash = usage_account_hash(id, heap)
	r.status = .Ok
	return r
}

@(private = "file")
sort_strings :: proc(s: []string) {
	for i in 1 ..< len(s) do for j := i; j > 0 && s[j] < s[j - 1]; j -= 1 do s[j], s[j - 1] = s[j - 1], s[j]
}
