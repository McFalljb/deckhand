package main

// Events: every command run (except queries) and every long command's finish.
// They go to the command log, the test mode and the control socket's
// subscribers (socket.odin, docs/PROTOCOL.md). Events never carry
// confirmation tokens or pasted text (see event_json).

import "core:fmt"
import "core:os"
import "core:path/filepath"

Command_Event :: struct {
	request_id: u64,
	caller:     Caller,
	version:    u64, // state.version after the command
	changed:    bool,
	command:    Command,
	result:     Result,
}

Finished_Event :: struct {
	request_id: u64,
	result:     Result,
	private:    bool, // its data is a web page's content (browser_read): only the requester gets it; the log and other subscribers see its size
}

Event :: union {
	Command_Event,
	Finished_Event,
	Job_Event, // job.finished (jobs.odin)
}

// Command log: <dir>/commands.log, rotated at LOG_CAP bytes into .1 and .2
// (three files at most).
LOG_CAP :: 10 * 1024 * 1024

@(private = "file")
log_file: ^os.File
@(private = "file")
log_path: string
@(private = "file")
log_size: i64
log_cap: i64 = LOG_CAP // tests lower it

// Opens <dir>/commands.log for appending (JSON lines). Called by the window
// layer at startup; without it events are not logged.
event_log_open :: proc(dir: string) {
	if !private_dir(dir) do return
	log_path, _ = filepath.join({dir, "commands.log"}, context.allocator)
	log_reopen()
}

// Makes `dir` (the data dir) private: created 0700, or set to 0700 if group
// or others had any access. False if it could not be created.
private_dir :: proc(dir: string) -> bool {
	OWNER :: os.Permissions{.Read_User, .Write_User, .Execute_User}
	if os.make_directory_all(dir, OWNER) != nil && !os.is_dir(dir) do return false
	if fi, err := os.stat(dir, context.temp_allocator); err == nil && fi.mode - OWNER != {} do os.chmod(dir, OWNER)
	return true
}

event_log_close :: proc() {
	if log_file != nil do os.close(log_file)
	log_file = nil
}

@(private = "file")
log_reopen :: proc() {
	f, err := os.open(log_path, {.Write, .Create, .Append}, {.Read_User, .Write_User})
	if err != nil do return
	log_file = f
	log_size, _ = os.file_size(f)
}

@(private = "file")
log_write :: proc(line: string) {
	if log_file == nil do return
	if log_size > 0 && log_size + i64(len(line)) + 1 > log_cap {
		event_log_close()
		p1 := fmt.tprintf("%s.1", log_path)
		p2 := fmt.tprintf("%s.2", log_path)
		os.remove(p2)
		os.rename(p1, p2)
		os.rename(log_path, p1)
		log_reopen()
		if log_file == nil do return
	}
	os.write_string(log_file, line)
	os.write_string(log_file, "\n")
	log_size += i64(len(line)) + 1
}

emit_event :: proc(ev: Event) {
	line := event_json(ev)
	log_write(line)
	if hook_env(.Log_Commands) != "" do fmt.println("[event]", line)
	autotest_on_event(ev)
	persist_on_event(ev)
	socket_publish(ev)
}

// A subscriber never receives events it caused itself (an agent reacting to
// its own commands would loop), and a caller bound to a tab (a pi tab's
// bridge, Home's control connection) never receives events about its own tab
// or session: its own status, panels, exit. Main thread.
event_visible_to :: proc(ev: Event, subscriber: Caller) -> bool {
	e, ok := ev.(Command_Event)
	if !ok || subscriber.tab_id == 0 do return true
	if e.caller.tab_id == subscriber.tab_id do return false
	if t := command_tab(e.command); t != 0 && owns_tab(subscriber, t) do return false
	if s := command_session(e.command); s != 0 && owns_session(subscriber, s) do return false
	return true
}
