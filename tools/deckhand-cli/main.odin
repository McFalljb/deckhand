package deckhand_cli

// `deckhand`: the command Claude Code runs inside a Deckhand Claude tab (the plugin's bin/pi-desk
// execs this binary, which ships inside Deckhand.app so plugin and app always match). It drives
// the tab's own session's browser and app tabs through Deckhand's control socket, prints one JSON
// object per call (page and app data only inside a fenced `content`), and is the plugin's hooks
// (`deckhand hook …`). Deckhand enforces every rule; this tool only shapes calls and output.
//
// Exit status: 0 ok, 1 the command failed (or Deckhand could not be reached), 2 usage.
// Hooks always exit 0, but for `hook readonly` (2 = the tool call is denied).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"
import "core:strings"
import "core:sys/posix"

MANUAL :: #load("manual.md", string)

Ctx :: struct {
	write_out:  proc(c: ^Ctx, s: string), // stdout (written at once: a hook's output goes before claude.attached)
	write_err:  proc(c: ^Ctx, s: string),
	read_stdin: proc() -> string,
	getenv:     proc(k: string) -> string,
	clock:      proc() -> u64, // a hook's order stamp (monotonic ns at its start); nil = none (tests)
	started:    u64, // clock() when run began (before stdin is read): the hook's seq
	tr:         ^Transport, // nil: made from the environment on first use
	out:        strings.Builder, // tests: what was written
	err:        strings.Builder,
}

main :: proc() {
	c := Ctx {
		write_out  = proc(c: ^Ctx, s: string) {fd_write(1, s)},
		write_err  = proc(c: ^Ctx, s: string) {fd_write(2, s)},
		read_stdin = stdin_all,
		getenv     = proc(k: string) -> string {return os.get_env(k, context.allocator)}, // env-read-ok: the CLI getenv wrapper: its callers are checked
		clock      = proc() -> u64 {return u64(time.tick_now()._nsec)},
	}
	code := run(&c, os.args[1:])
	if c.tr != nil do transport_close(c.tr)
	os.exit(code)
}

fd_write :: proc(fd: posix.FD, s: string) {
	rest := transmute([]u8)s
	for len(rest) > 0 {
		n := posix.write(fd, raw_data(rest), len(rest))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do return
		rest = rest[n:]
	}
}

STDIN_MAX :: 4 << 20

stdin_all :: proc() -> string {
	b: [dynamic]u8
	chunk: [16 * 1024]u8
	for len(b) < STDIN_MAX {
		n := posix.read(0, raw_data(chunk[:]), len(chunk))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do break
		append(&b, ..chunk[:n])
	}
	return string(b[:])
}

// The transport from DECKHAND_SOCKET and DECKHAND_CLAUDE_TOKEN, or why there is none.
transport :: proc(c: ^Ctx, hello_ms := 5000) -> (^Transport, string) {
	if c.tr != nil do return c.tr, ""
	path := c.getenv("DECKHAND_SOCKET")
	token := c.getenv("DECKHAND_CLAUDE_TOKEN")
	if path == "" || token == "" do return nil, "not inside a Deckhand Claude tab (DECKHAND_SOCKET or DECKHAND_CLAUDE_TOKEN is not set)"
	t := new(Transport)
	t^ = real_transport(path, token, hello_ms)
	c.tr = t
	return t, ""
}

println_out :: proc(c: ^Ctx, s: string) {c.write_out(c, strings.concatenate({s, "\n"}))}

run :: proc(c: ^Ctx, args: []string) -> int {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
		c.write_out(c, strings.concatenate({USAGE, "\n"}))
		return len(args) == 0 ? 2 : 0
	}
	if args[0] == "--skill" {
		c.write_out(c, MANUAL)
		return 0
	}
	if args[0] == "hook" && len(args) > 1 && args[1] == "readonly-ack" {
		// the read-only profile loaded (its SessionStart hook, readonly.odin): exit 0 whatever
		hook_readonly_ack(c, len(args) > 2 ? args[2] : "")
		return 0
	}
	if args[0] == "hook" && len(args) > 1 && args[1] == "readonly" {
		// the read-only guard (readonly.odin): exit 2 denies; it never needs Deckhand's socket
		return hook_readonly(c)
	}
	if args[0] == "hook" {
		if c.clock != nil && c.started == 0 do c.started = c.clock() // the hook's start, before its stdin
		run_hook(c, len(args) > 1 ? args[1] : "")
		return 0
	}
	req, uerr := parse_cli(args, c.read_stdin)
	if uerr != "" {
		w := jw_begin()
		jw_bool(&w, "ok", false)
		if req.name != "" do jw_str(&w, "command", req.name)
		jw_str(&w, "error", uerr)
		jw_str(&w, "usage", "deckhand --help (or deckhand --skill for the manual)")
		println_out(c, jw_end(&w))
		return 2
	}
	t, terr := transport(c)
	if terr != "" {
		println_out(c, local_error(req.name, terr))
		return 1
	}
	result, err := t.call(t, req.cmd, req.timeout_ms)
	if err != "" {
		println_out(c, local_error(req.name, err))
		return 1
	}
	if !is_true(result, "ok") {
		println_out(c, req.kind == .Show ? show_error_out(&req, result) : error_out(&req, result))
		return 1
	}
	out, code := format_ok(c, &req, result)
	println_out(c, out)
	return code
}

format_ok :: proc(c: ^Ctx, req: ^Req, result: json.Object) -> (string, int) {
	d := get_obj(result, "data")
	switch req.kind {
	case .Tabs:       return tabs_out(req, d), 0
	case .Open:       return open_out(req, result), 0
	case .Nav:        return nav_out(req), 0
	case .Read:       return read_out(req, d), 0
	case .Wait:       return wait_out(req, d), 0
	case .Console, .Network: return log_out(req, d), 0
	case .Comments:   return comments_out(req, d), 0
	case .Act:        return act_out(req, d), 0
	case .App_Call:   return app_call_out(req, result), 0
	case .App_Input:  return app_input_out(req, d, req.n_events), 0
	case .App_Events: return app_events_out(req, d), 0
	case .App_Open:   return app_open_out(req, result), 0
	case .App_Tab_Op: return app_tab_op_out(req), 0
	case .App_Declared: return app_declared_out(req, d), 0
	case .State:      return state_out(req, result), 0
	case .Show:       return show_out(req, result), 0
	case .Shot, .App_Shot:
		return shot_out(req, d, c.getenv("DECKHAND_SHOTS_DIR"))
	}
	return local_error(req.name, "unknown command kind"), 1
}

shot_out :: proc(req: ^Req, d: json.Object, shots_dir: string) -> (string, int) {
	path, why := shot_check(req.tab, get_text(d, "path"), shots_dir)
	if why != "" do return local_error(req.name, fmt.aprintf("the screenshot Deckhand wrote is not usable: %s", why)), 1
	w := ok_begin(req)
	jw_str(&w, "path", path)
	for k in ([]string{"w", "h", "bytes", "scale", "seq", "tick"}) do if n, ok := get_num(d, k); ok do jw_num(&w, k, n)
	if r := get_obj(d, "rect"); r != nil {
		rw := jw_begin()
		for k in ([]string{"x", "y", "w", "h"}) do if n, ok := get_num(r, k); ok do jw_num(&rw, k, n)
		jw_raw(&w, "rect", jw_end(&rw))
	}
	if req.kind == .Shot {
		if v, has := get_bool(d, "on_screen"); has do jw_bool(&w, "on_screen", v)
		hidden := is_false(d, "on_screen") ? " The tab is not on screen (no pane shows it): Deckhand painted it for this, unseen." : ""
		jw_str(&w, "note", strings.concatenate({SHOT_NOTE, hidden, READ_IT}))
	} else {
		if v, has := get_bool(d, "visible"); has do jw_bool(&w, "visible", v)
		hidden := is_false(d, "visible") ? " The tab is not on screen (no pane shows it): the last frame it showed." : ""
		jw_str(&w, "note", strings.concatenate({APP_SHOT_NOTE, hidden, READ_IT}))
	}
	return jw_end(&w), 0
}
