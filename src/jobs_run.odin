#+build darwin, linux
package main

// One job run (docs/ATLAS.md §3.7, §4.4, §4.5): a fresh one-shot
// `pi --mode json` in the job's folder, with a preamble, an environment
// allowlist (no pi-desk socket or tokens) and stdin /dev/null, in its own
// process group. A reader thread copies pi's JSON events to the run
// folder's events.jsonl and watches them:
//
//   - the loop detector: the same tool call (tool + arguments) N times in a
//     row stops the run (`looping`)
//   - per-run limits, when set: cost (usage.cost) and turns (`over_limit`)
//   - guardrails' "Needs user approval" results: the blocked action is kept
//     (tool, command, cwd, sha256) and the run ends `needs_you`
//   - the final answer (the report, jobs_note.odin)
//
// The scheduler (jobs_watch) stops a run that is silent too long
// (`stalled`) or over its timeout (`timeout`). A stop signals pi's whole
// tree: its process group and every descendant found by walking children
// (pi's bash tool starts commands in their own process groups), SIGTERM,
// then SIGKILL 5 s later to everything seen either time. events.jsonl is
// capped: at EVENTS_CAP it moves to events.jsonl.1 (one old file). When pi's output ends the reader reaps it and posts
// Job_Run_Done; jobs.odin writes the record and delivers.
//
// The run lock: <data dir>/jobs/<id>/run.lock (flock, non-blocking), held
// by pi-desk and inherited by pi, so it lives exactly as long as the run.

import "base:runtime"
import "core:c"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

when ODIN_OS == .Darwin {
	foreign import jlibc "system:System"
} else {
	foreign import jlibc "system:c"
}
@(default_calling_convention = "c")
foreign jlibc {
	flock :: proc(fd: c.int, op: c.int) -> c.int ---
}
when ODIN_OS == .Darwin {
	@(default_calling_convention = "c")
	foreign jlibc {
		proc_listchildpids :: proc(ppid: posix.pid_t, buffer: rawptr, buffersize: c.int) -> c.int ---
	}
}

EVENTS_CAP :: 5 * 1024 * 1024
LOCK_EX :: 2
LOCK_NB :: 4

Run_Stop :: enum u8 {
	None,
	Looping,
	Stalled,
	Over_Limit,
	Timeout,
	User, // job_stop
	Quit, // pi-desk quit
}

Blocked_Action :: struct {
	tool, command, cwd, sha256: string,
}

Job_Run :: struct {
	job_id:       string,
	name:         string, // the run folder's name
	dir:          string,
	scheduled_at: i64,
	started:      i64, // wall clock
	started_tick: time.Tick,
	pid:          posix.pid_t,
	out_fd:       posix.FD,
	lock_fd:      c.int,
	th:           ^thread.Thread,
	cwd:          string,
	// limits for this run (0 = off)
	max_cost:     f64,
	max_turns:    int,
	timeout:      i64,
	loop_calls:   int,
	stall:        i64,
	// written by the reader, read by the main thread (mu)
	mu:           sync.Mutex,
	last_event:   time.Tick,
	cost:         f64,
	turns:        int,
	tokens:       i64,
	same_calls:   int,
	last_call:    u64,
	final_text:   string, // the last assistant message's text
	error_text:   string, // the last assistant message's error, if it failed
	blocked:      [dynamic]Blocked_Action,
	commands:     map[string]string, // toolCallId -> its command (blocked actions)
	stop:         Run_Stop,
	stop_at:      time.Tick, // SIGTERM sent: SIGKILL after RUN_KILL_AFTER
	killed:       bool,
	tree:         [dynamic]posix.pid_t, // pi's descendants seen at the stop (SIGKILLed with it)
	exit_code:    int, // set by the reader at the end
	spawn_error:  string,
}

RUN_KILL_AFTER :: 5 * time.Second

// Starts pi for a run. argv[0] absolute; env "K=V". The child joins its own
// process group, reads /dev/null, writes stdout to a pipe and stderr to
// stderr_path, and keeps lock_fd (so the run lock lives as long as it).
run_spawn :: proc(r: ^Job_Run, argv, env: []string, cwd, stderr_path: string) -> bool {
	c_argv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do c_argv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	c_env := make([]cstring, len(env) + 1, context.temp_allocator)
	for e, i in env do c_env[i] = strings.clone_to_cstring(e, context.temp_allocator)
	c_cwd := strings.clone_to_cstring(cwd, context.temp_allocator)
	errf := posix.open(strings.clone_to_cstring(stderr_path, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR})
	null := posix.open("/dev/null", {.CLOEXEC})
	fds: [2]posix.FD
	if errf < 0 || null < 0 || posix.pipe(&fds) != .OK {
		if errf >= 0 do posix.close(errf)
		if null >= 0 do posix.close(null)
		return false
	}
	// neither end reaches another child (a shell opened during the run); dup2 into pi's stdout clears it there
	posix.fcntl(fds[0], .SETFD, i32(posix.FD_CLOEXEC))
	posix.fcntl(fds[1], .SETFD, i32(posix.FD_CLOEXEC))
	lock := posix.FD(r.lock_fd)
	sync.rw_mutex_shared_lock(&fork_lock) // fork_lock, pty.odin
	pid := posix.fork()
	if pid != 0 do sync.rw_mutex_shared_unlock(&fork_lock)
	if pid < 0 {
		posix.close(fds[0])
		posix.close(fds[1])
		posix.close(errf)
		posix.close(null)
		return false
	}
	if pid == 0 {
		// only async-signal-safe calls from here
		posix.setpgid(0, 0)
		posix.dup2(null, 0)
		posix.dup2(fds[1], 1)
		posix.dup2(errf, 2)
		for fd in posix.FD(3) ..< 256 do if fd != lock do posix.close(fd)
		posix.fcntl(lock, .SETFD, i32(0)) // pi keeps the run lock (close-on-exec for every other child)
		if posix.chdir(c_cwd) != .OK do posix._exit(126)
		posix.execve(c_argv[0], raw_data(c_argv), raw_data(c_env))
		posix._exit(127)
	}
	posix.setpgid(pid, pid) // also from here: no race with an early kill
	posix.close(fds[1])
	posix.close(errf)
	posix.close(null)
	r.pid = pid
	r.out_fd = fds[0]
	r.last_event = time.tick_now()
	r.started_tick = r.last_event
	r.th = thread.create_and_start_with_poly_data(r, run_reader)
	return true
}

// The processes below pid (children first found, then theirs), added to out.
proc_tree :: proc(pid: posix.pid_t, out: ^[dynamic]posix.pid_t) {
	when ODIN_OS == .Darwin {
		buf: [512]posix.pid_t
		n := proc_listchildpids(pid, &buf[0], c.int(size_of(buf)))
		for i in 0 ..< clamp(int(n), 0, len(buf)) {
			k := buf[i]
			if k <= 1 do continue
			seen := false
			for x in out^ do if x == k do seen = true
			if seen do continue
			append(out, k)
			if len(out^) < 4096 do proc_tree(k, out)
		}
	} else {
		data, err := os.read_entire_file(fmt.tprintf("/proc/%d/task/%d/children", pid, pid), context.temp_allocator)
		if err != nil do return
		for f in strings.fields(string(data), context.temp_allocator) {
			k := posix.pid_t(strconv.atoi(f))
			if k <= 1 do continue
			seen := false
			for x in out^ do if x == k do seen = true
			if seen do continue
			append(out, k)
			if len(out^) < 4096 do proc_tree(k, out)
		}
	}
}

// Signals pi's tree: its group, every descendant now, and (SIGKILL) every
// one seen before. r.mu held.
@(private = "file")
run_signal :: proc(r: ^Job_Run, sig: posix.Signal) {
	if r.tree.allocator.procedure == nil do r.tree.allocator = runtime.heap_allocator()
	if r.pid > 0 { 	// 0 once reaped: its pid may belong to someone else now
		proc_tree(r.pid, &r.tree)
		posix.kill(-r.pid, sig)
	}
	for k in r.tree {
		posix.kill(k, sig)
		posix.kill(-k, sig) // its own group, if it leads one
	}
}

// Asks the run to stop: SIGTERM to pi's tree (SIGKILL follows from
// jobs_watch). The first reason sticks.
run_stop :: proc(r: ^Job_Run, why: Run_Stop) {
	sync.lock(&r.mu)
	defer sync.unlock(&r.mu)
	if r.stop != .None do return
	r.stop = why
	r.stop_at = time.tick_now()
	run_signal(r, .SIGTERM)
}

// SIGKILL to pi's tree now (quit, or 5 s after a stop).
run_kill :: proc(r: ^Job_Run) {
	sync.lock(&r.mu)
	defer sync.unlock(&r.mu)
	run_signal(r, .SIGKILL)
	r.killed = true
}

// Called from the main thread about once a second: SIGKILL after a stop
// that did not take, the stall watchdog and the timeout.
run_watch :: proc(r: ^Job_Run, now: i64) {
	sync.lock(&r.mu)
	stop, stop_at, killed, last := r.stop, r.stop_at, r.killed, r.last_event
	sync.unlock(&r.mu)
	sync.lock(&r.mu)
	reaped := r.pid == 0
	sync.unlock(&r.mu)
	if reaped do return // Job_Run_Done is on its way (job_finish kills what is left)
	if stop != .None {
		if !killed && time.tick_since(stop_at) > RUN_KILL_AFTER do run_kill(r)
		return
	}
	if r.stall > 0 && time.duration_seconds(time.tick_since(last)) >= f64(r.stall) do run_stop(r, .Stalled)
	else if r.timeout > 0 && now - r.started >= r.timeout do run_stop(r, .Timeout)
}

@(private = "file")
run_reader :: proc(r: ^Job_Run) {
	ev_path := fmt.aprintf("%s/events.jsonl", r.dir)
	defer delete(ev_path)
	out, _ := os.open(ev_path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	defer if out != nil do os.close(out)
	written := 0
	buf: [64 * 1024]u8
	line := make([dynamic]u8)
	defer delete(line)
	for {
		n := posix.read(r.out_fd, raw_data(buf[:]), len(buf))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do break
		chunk := buf[:n]
		if out != nil {
			if written + len(chunk) > EVENTS_CAP {
				// the newest events matter most: the old file goes, this one becomes .1
				os.close(out)
				old := fmt.tprintf("%s.1", ev_path)
				os.remove(old)
				os.rename(ev_path, old)
				out, _ = os.open(ev_path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
				written = 0
			}
			if out != nil do os.write(out, chunk)
			written += len(chunk)
		}
		for b in chunk {
			if b != '\n' {
				if len(line) < 16 * 1024 * 1024 do append(&line, b) // a huge line is cut, not kept whole
				continue
			}
			run_event(r, string(line[:]))
			clear(&line)
			free_all(context.temp_allocator)
		}
	}
	if len(line) > 0 do run_event(r, string(line[:]))
	posix.close(r.out_fd)
	status: c.int
	for posix.waitpid(r.pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	code := 1
	if posix.WIFEXITED(status) do code = int(posix.WEXITSTATUS(status))
	else if posix.WIFSIGNALED(status) do code = 128 + int(posix.WTERMSIG(status))
	sync.lock(&r.mu)
	r.exit_code = code
	r.pid = 0 // reaped: never signal this pid again
	sync.unlock(&r.mu)
	inbox_submit(Job_Run_Done{run = r}, {kind = .Internal})
}

// One JSON event from pi (docs/json.md of pi).
@(private = "file")
run_event :: proc(r: ^Job_Run, line: string) {
	sync.lock(&r.mu)
	r.last_event = time.tick_now()
	sync.unlock(&r.mu)
	v, err := json.parse_string(line, .JSON, true, context.temp_allocator)
	if err != nil do return
	o, ok := v.(json.Object)
	if !ok do return
	typ, _ := o["type"].(json.String)
	switch typ {
	case "tool_execution_start":
		tool, _ := o["toolName"].(json.String)
		args_json, _ := json.marshal(o["args"], {sort_maps_by_key = true}, context.temp_allocator)
		h := hash.fnv64a(transmute([]u8)strings.concatenate({string(tool), "\x00", string(args_json)}, context.temp_allocator))
		id, _ := o["toolCallId"].(json.String)
		cmd := ""
		if a, aok := o["args"].(json.Object); aok {
			if s, sok := a["command"].(json.String); sok do cmd = string(s)
			else if s, sok2 := a["path"].(json.String); sok2 do cmd = string(s)
		}
		sync.lock(&r.mu)
		if h == r.last_call && r.same_calls > 0 do r.same_calls += 1
		else do r.same_calls = 1
		r.last_call = h
		loop := r.loop_calls > 0 && r.same_calls >= r.loop_calls
		if id != "" && len(r.commands) < 10_000 do r.commands[strings.clone(string(id))] = strings.clone(cmd)
		sync.unlock(&r.mu)
		if loop do run_stop(r, .Looping)
	case "tool_execution_end":
		is_err, _ := o["isError"].(json.Boolean)
		if !is_err do return
		text := result_text(o["result"])
		if !strings.contains(text, "Needs user approval") do return
		tool, _ := o["toolName"].(json.String)
		id, _ := o["toolCallId"].(json.String)
		sync.lock(&r.mu)
		defer sync.unlock(&r.mu)
		cmd := r.commands[string(id)] or_else ""
		sum: [sha2.DIGEST_SIZE_256]u8
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		sha2.update(&ctx, transmute([]u8)strings.concatenate({string(tool), "\x00", cmd, "\x00", r.cwd}, context.temp_allocator))
		sha2.final(&ctx, sum[:])
		if len(r.blocked) < 50 do append(&r.blocked, Blocked_Action{tool = strings.clone(string(tool)), command = strings.clone(cmd), cwd = strings.clone(r.cwd), sha256 = string(hex.encode(sum[:]))})
	case "turn_end":
		sync.lock(&r.mu)
		r.turns += 1
		over := r.max_turns > 0 && r.turns >= r.max_turns
		sync.unlock(&r.mu)
		if over do run_stop(r, .Over_Limit)
	case "message_end":
		m, _ := o["message"].(json.Object)
		role, _ := m["role"].(json.String)
		if role != "assistant" do return
		cost := 0.0
		tokens: i64
		if u, uok := m["usage"].(json.Object); uok {
			if cobj, cok := u["cost"].(json.Object); cok do cost = num(cobj["total"])
			tokens = i64(num(u["totalTokens"]))
		}
		text := result_text(m)
		stop, _ := m["stopReason"].(json.String)
		emsg, _ := m["errorMessage"].(json.String)
		sync.lock(&r.mu)
		r.cost += cost
		r.tokens += tokens
		if strings.trim_space(text) != "" {
			delete(r.final_text)
			r.final_text = strings.clone(text)
		}
		delete(r.error_text)
		r.error_text = stop == "error" || stop == "aborted" ? strings.clone(emsg != "" ? string(emsg) : string(stop)) : ""
		over := r.max_cost > 0 && r.cost >= r.max_cost
		sync.unlock(&r.mu)
		if over do run_stop(r, .Over_Limit)
	}
}

@(private = "file")
num :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Float:   return f64(n)
	case json.Integer: return f64(n)
	}
	return 0
}

// The text parts of a message or tool result ({content: [{type: text, text}]} or a string).
@(private = "file")
result_text :: proc(v: json.Value) -> string {
	o, ok := v.(json.Object)
	if !ok do return ""
	if s, is := o["content"].(json.String); is do return string(s)
	parts, _ := o["content"].(json.Array)
	b := strings.builder_make(context.temp_allocator)
	for p in parts {
		po, _ := p.(json.Object)
		if t, _ := po["type"].(json.String); t != "text" do continue
		s, _ := po["text"].(json.String)
		if strings.builder_len(b) > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, string(s))
	}
	return strings.to_string(b)
}

// Takes the job's run lock (non-blocking); -1 when another run holds it.
run_lock :: proc(path: string) -> c.int {
	// close-on-exec: a shell started during the run must not keep the lock
	// past it (run_spawn hands it to pi on purpose)
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.RDWR, .CREAT, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 do return -1
	if flock(c.int(fd), LOCK_EX | LOCK_NB) != 0 {
		posix.close(fd)
		return -1
	}
	return c.int(fd)
}

// Frees what the run owns (after Job_Run_Done, its thread joined).
run_free :: proc(r: ^Job_Run) {
	if r.th != nil {
		thread.join(r.th)
		thread.destroy(r.th)
	}
	if r.lock_fd >= 0 do posix.close(posix.FD(r.lock_fd))
	delete(r.job_id)
	delete(r.name)
	delete(r.dir)
	delete(r.cwd)
	delete(r.final_text)
	delete(r.error_text)
	delete(r.spawn_error)
	for b in r.blocked {
		delete(b.tool)
		delete(b.command)
		delete(b.cwd)
		delete(b.sha256)
	}
	delete(r.blocked)
	for k, v in r.commands {
		delete(k)
		delete(v)
	}
	delete(r.commands)
	delete(r.tree)
	free(r)
}
