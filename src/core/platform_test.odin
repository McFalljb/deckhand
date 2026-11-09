package core

import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

// A release build's data dir (and so the runtime socket, tokens.json and the holder's files) comes
// from the account's home in the user database, never from $HOME: an environment can't move it.
@(test)
account_home_ignores_env :: proc(t: ^testing.T) {
	saved := os.get_env("HOME", context.temp_allocator)
	defer os.set_env("HOME", saved)
	a := account_home(context.temp_allocator)
	testing.expect(t, strings.has_prefix(a, "/") && len(a) > 1, a)
	os.set_env("HOME", "/tmp/not-the-home")
	testing.expect_value(t, account_home(context.temp_allocator), a)
	testing.expect_value(t, data_home(false, context.temp_allocator), a) // release: the account's
	testing.expect_value(t, data_home(true, context.temp_allocator), "/tmp/not-the-home") // test builds: HOME (scenes set it)
}

// getpwuid_r's buffer is grown on ERANGE; no entry (or a relative home) never gives a relative
// data dir: data_dir_under says "" and the launch refuses to start (main.odin).
@(test)
account_home_failures :: proc(t: ^testing.T) {
	@(static) calls: int
	calls = 0
	big := proc(buf: []u8) -> (dir: string, err: posix.Errno) {
		calls += 1
		if len(buf) < 20000 do return "", .ERANGE
		return "/Users/big", .NONE
	}
	testing.expect_value(t, account_home_with(big, context.temp_allocator), "/Users/big")
	testing.expect(t, calls > 1, "not retried")
	none := proc(buf: []u8) -> (dir: string, err: posix.Errno) {return "", .NONE}
	testing.expect_value(t, account_home_with(none, context.temp_allocator), "")
	erange := proc(buf: []u8) -> (dir: string, err: posix.Errno) {return "", .ERANGE}
	testing.expect_value(t, account_home_with(erange, context.temp_allocator), "") // gives up at a cap
	testing.expect_value(t, data_dir_under("", context.temp_allocator), "")
	testing.expect_value(t, data_dir_under("relative/home", context.temp_allocator), "")
	d := data_dir_under("/Users/x", context.temp_allocator)
	testing.expect(t, strings.has_prefix(d, "/Users/x/"), d)
}
