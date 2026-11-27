package deckhand_cli

// `deckhand statusline`: Claude Code's status line in a Deckhand Claude tab (Deckhand starts the
// tab with `--settings '{"statusLine":{"type":"command","command":"<this> statusline",…}}'`;
// docs/CLAUDE-TABS.md §6c). Claude Code runs it with its status line JSON on stdin at each footer
// update. It sends Deckhand only the plan numbers of that JSON's rate_limits (claude.usage: the
// five-hour and weekly windows' used_percentage and resets_at, a spend limit's), never the
// transcript path, folder, session, model or anything else; then runs the user's own status line
// (the command Deckhand answers with: the tab's account's and project's settings) with the same
// stdin, and its output goes out unchanged, byte for byte, with its exit status. With no Deckhand
// to ask (outside a Deckhand tab, the socket gone) or no status line of the user's it prints
// nothing: Claude Code has no status line text of its own to fall back to.

import "core:encoding/json"
import "core:strings"
import "core:sys/posix"

STATUSLINE_HELLO_MS :: 1500 // Claude Code redraws the footer when it ends: never long
STATUSLINE_CALL_MS :: 1500
// Set for the user's status line: a status line that runs `deckhand statusline` again (copied
// into their settings) prints nothing, rather than run itself forever.
STATUSLINE_DEPTH_ENV :: "DECKHAND_STATUSLINE_DEPTH"

// The claude.usage command from Claude Code's status line JSON: the numbers only.
statusline_cmd :: proc(input: string) -> string {
	w := jw_begin()
	jw_str(&w, "type", "claude.usage")
	o, _ := parse_obj(input)
	rl := get_obj(o, "rate_limits")
	pct :: proc(w: ^JW, o: json.Object, key: string) {
		if p, ok := get_num(o, "used_percentage"); ok do jw_num(w, key, p)
	}
	when_ :: proc(w: ^JW, o: json.Object, key: string) {
		// Unix seconds, before the year 3000 (Deckhand checks again)
		if t, ok := get_num(o, "resets_at"); ok && t > 0 && t < 32503680000 do jw_int(w, key, i64(t))
	}
	if x := get_obj(rl, "five_hour"); x != nil {
		pct(&w, x, "five_hour")
		when_(&w, x, "five_hour_resets")
	}
	if x := get_obj(rl, "seven_day"); x != nil {
		pct(&w, x, "seven_day")
		when_(&w, x, "seven_day_resets")
	}
	if x := get_obj(rl, "spend_limit"); x != nil {
		pct(&w, x, "spend")
		when_(&w, x, "spend_resets")
		if u, ok := get_num(x, "used_usd"); ok do jw_num(&w, "spend_used_usd", u)
		if l, ok := get_num(x, "limit_usd"); ok do jw_num(&w, "spend_limit_usd", l)
	}
	return jw_end(&w)
}

// The status line: 0, or the user's status line's exit status.
run_statusline :: proc(c: ^Ctx) -> int {
	raw := c.read_stdin != nil ? c.read_stdin() : ""
	if c.getenv("DECKHAND_STATUSLINE_DEPTH") != "" do return 0 // the user's own runs this again: nothing
	path, token := tab_env(c)
	if path == "" || token == "" do return 0 // not a Deckhand tab: nothing to say, nothing to run
	t, terr := transport(c, STATUSLINE_HELLO_MS)
	if terr != "" do return 0
	r, err := t.call(t, statusline_cmd(raw), STATUSLINE_CALL_MS)
	if err != "" || !is_true(r, "ok") do return 0 // Deckhand gone or refusing: no footer, never an error in it
	user, _ := get_str(get_obj(r, "data"), "command")
	if strings.trim_space(user) == "" do return 0
	if c.run_cmd != nil do return c.run_cmd(c, user, raw)
	return statusline_run_user(c, user, raw)
}

// The user's status line as Claude Code runs one: `/bin/sh -c COMMAND` in this folder, with this
// environment (and STATUSLINE_DEPTH_ENV), the same stdin; its stdout through write_out as it
// comes, its stderr to ours. Its exit status (1 when it could not start or was killed).
statusline_run_user :: proc(c: ^Ctx, command, stdin_text: string) -> int {
	pin, pout: [2]posix.FD
	if posix.pipe(&pin) != .OK do return 1
	if posix.pipe(&pout) != .OK {
		posix.close(pin[0])
		posix.close(pin[1])
		return 1
	}
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN) // a command that does not read its stdin
	ccmd := strings.clone_to_cstring(command)
	argv := [4]cstring{"/bin/sh", "-c", ccmd, nil}
	posix.setenv(STATUSLINE_DEPTH_ENV, "1", true)
	pid := posix.fork()
	if pid < 0 {
		for fd in ([4]posix.FD{pin[0], pin[1], pout[0], pout[1]}) do posix.close(fd)
		return 1
	}
	if pid == 0 {
		posix.dup2(pin[0], 0)
		posix.dup2(pout[1], 1)
		for fd in ([4]posix.FD{pin[0], pin[1], pout[0], pout[1]}) do posix.close(fd)
		posix.execv("/bin/sh", raw_data(argv[:]))
		posix._exit(127)
	}
	posix.close(pin[0])
	posix.close(pout[1])
	// its stdin written and its stdout read as each is ready (a command may write before it reads)
	rest := transmute([]u8)stdin_text
	if len(rest) == 0 {
		posix.close(pin[1])
		pin[1] = -1
	} else {
		fl := posix.fcntl(pin[1], .GETFL)
		posix.fcntl(pin[1], .SETFL, fl | i32(posix.O_Flags{.NONBLOCK}))
	}
	buf: [16 << 10]u8
	for {
		fds: [2]posix.pollfd
		n: u32 = 0
		fds[0] = {fd = pout[0], events = {.IN}}
		n = 1
		if pin[1] >= 0 {
			fds[1] = {fd = pin[1], events = {.OUT}}
			n = 2
		}
		if posix.poll(&fds[0], posix.nfds_t(n), -1) < 0 {
			if posix.errno() == .EINTR do continue
			break
		}
		if n == 2 && fds[1].revents != {} {
			w := posix.write(pin[1], raw_data(rest), len(rest))
			if w > 0 do rest = rest[w:]
			if (w < 0 && posix.errno() != .EAGAIN && posix.errno() != .EINTR) || len(rest) == 0 {
				posix.close(pin[1])
				pin[1] = -1
			}
		}
		if fds[0].revents != {} {
			got := posix.read(pout[0], &buf[0], len(buf))
			if got < 0 && posix.errno() == .EINTR do continue
			if got <= 0 do break
			c.write_out(c, string(buf[:got]))
		}
	}
	if pin[1] >= 0 do posix.close(pin[1])
	posix.close(pout[0])
	status: i32
	for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	if posix.WIFEXITED(status) do return int(posix.WEXITSTATUS(status))
	return 1
}
