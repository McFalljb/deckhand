#+build darwin
package holder

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
SECRET :: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

@(private = "file")
Serve :: struct {
	lfd:      c.int,
	exe:      string,
	ttl:      time.Duration,
	took:     bool,
	finished: bool,
}

// A client of successor.sock as the new app is (src/holder_successor.odin): our pid, then the
// secret line ("" if closed or refused), then "ok".
@(private = "file")
client :: proc(path: string, claim: int) -> string {
	addr := Sockaddr_Un{sun_family = AF_UNIX}
	copy(addr.sun_path[:], path)
	addr.sun_len = size_of(addr)
	fd := socket(AF_UNIX, SOCK_STREAM, 0)
	defer close(fd)
	set_nosigpipe(fd)
	if posix.connect(posix.FD(fd), (^posix.sockaddr)(&addr), size_of(addr)) != .OK do return "connect failed"
	s := fmt.tprintf("%d\n", claim)
	send(fd, raw_data(s), len(s), 0)
	buf: [128]u8
	n := 0
	deadline := time.tick_add(time.tick_now(), 3 * time.Second)
	for n < len(buf) && time.tick_diff(time.tick_now(), deadline) > 0 {
		pfd := Pollfd{fd = fd, events = POLLIN}
		if poll(&pfd, 1, 100) <= 0 do continue
		r := read(fd, &buf[n], c.size_t(len(buf) - n))
		if r <= 0 do break
		n += int(r)
		if buf[n - 1] == '\n' do break
	}
	line := string(buf[:n])
	if strings.has_suffix(line, "\n") do send(fd, raw_data(string("ok\n")), 3, 0)
	return strings.clone(strings.trim_suffix(line, "\n"), context.temp_allocator)
}

@(private = "file")
start_serve :: proc(t: ^testing.T, dir, exe: string, ttl: time.Duration) -> (^Serve, ^thread.Thread, string) {
	path := fmt.tprintf("%s/%s", dir, SUCCESSOR_SOCK)
	lfd, ok := relaunch_listen(dir, path)
	testing.expect(t, ok, "listen")
	s := new(Serve)
	s^ = {lfd = lfd, exe = exe, ttl = ttl}
	th := thread.create_and_start_with_poly_data(s, proc(s: ^Serve) {
		s.took = relaunch_serve(s.lfd, SECRET, s.exe, time.tick_add(time.tick_now(), s.ttl))
		s.finished = true
	})
	return s, th, path
}

@(private = "file")
temp_run_dir :: proc(t: ^testing.T) -> string {
	tmpl := strings.clone_to_cstring(fmt.tprintf("%s/dkrl.XXXXXX", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")), context.temp_allocator)
	d := posix.mkdtemp(transmute([^]u8)tmpl)
	testing.expect(t, d != nil)
	return strings.clone(string(d), context.temp_allocator)
}

// The new app (this process, running the expected executable) gets the secret once; a peer that
// claims another pid, or runs another executable, gets nothing and the helper keeps waiting.
@(test)
relaunch_hands_the_secret_to_the_new_app_only :: proc(t: ^testing.T) {
	dir := temp_run_dir(t)
	defer os.remove(dir)
	self := pid_path_for_test(getpid())
	s, th, path := start_serve(t, dir, self, 3 * time.Second)
	testing.expect_value(t, client(path, int(getpid()) + 1), "") // a pid that is not the peer's
	got := client(path, int(getpid()))
	testing.expect_value(t, got, SECRET)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, s.took)
	close(s.lfd)
	unlink(strings.clone_to_cstring(path, context.temp_allocator))
	free(s)

	// waiting for another executable: this process is refused, and the secret expires
	s, th, path = start_serve(t, dir, "/bin/sh", 400 * time.Millisecond)
	testing.expect_value(t, client(path, int(getpid())), "")
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, s.finished && !s.took)
	close(s.lfd)
	unlink(strings.clone_to_cstring(path, context.temp_allocator))
	free(s)
}

// The listening socket's dir must be a private one of ours; the arguments must be absolute.
@(test)
relaunch_refuses_bad_setups :: proc(t: ^testing.T) {
	_, ok := relaunch_listen("/tmp", "/tmp/" + SUCCESSOR_SOCK) // others can write /tmp
	testing.expect(t, !ok)
	_, aok := relaunch_args_parse({"--pid", "123", "--app", "rel/Deckhand.app", "--exe", "/x", "--run", "/r"})
	testing.expect(t, !aok, "a relative app path")
	a, pok := relaunch_args_parse({"--pid", "123", "--app", "/A.app", "--exe", "/x", "--run", "/r", "--no-open"})
	testing.expect(t, pok && a.pid == 123 && a.no_open)
	_, bok := relaunch_args_parse({"--pid", "1", "--app", "/A.app", "--exe", "/x", "--run", "/r"})
	testing.expect(t, !bok, "launchd's pid")
	_, sok := relaunch_args_parse({"--pid", "123", "--app", "/A.app", "--exe", "/x", "--run", "/r", "--secret", "ab"})
	testing.expect(t, !sok, "no secret in argv")
}

@(private = "file")
pid_path_for_test :: proc(pid: c.int) -> string {
	buf: [4096]u8
	n := proc_pidpath(pid, &buf[0], u32(len(buf)))
	return strings.clone(string(buf[:max(n, 0)]), context.temp_allocator)
}
