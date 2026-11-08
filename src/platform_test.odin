package main

import "core:os"
import "core:strings"
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
