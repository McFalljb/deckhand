package core

// The Linux core's systemd user unit and linger (systemd_unit.odin; §10.4 M6-L2): the unit's text,
// the systemctl and loginctl argv, and the linger parse. Pure, so they run on a Mac too.

import "core:strings"
import "core:testing"

@(test)
systemd_unit_text_fields :: proc(t: ^testing.T) {
	text, ok := systemd_unit_text("/home/u/.local/share/deckhand/core/current/deckhand-core-serve", "/home/u/.local/state/deckhand/run", "/home/u/.local/share/deckhand")
	testing.expect(t, ok)
	want := []string{
		"[Unit]\n",
		"StartLimitIntervalSec=60\nStartLimitBurst=5\n", // a failing core stops retrying (RestartSec alone never trips the default)
		"[Service]\nType=exec\n", // start fails when the binary cannot run, so the direct fallback runs
		`ExecStart="/home/u/.local/share/deckhand/core/current/deckhand-core-serve" serve --run "/home/u/.local/state/deckhand/run" --data "/home/u/.local/share/deckhand"` + "\n",
		"Environment=DECKHAND_GUI_LAUNCH=1\n", // the login shell's environment, as a launchd launch gets
		"Restart=on-failure\n",
		"RestartPreventExitStatus=2 3\n", // usage, and another core already running
		"KillMode=process\n", // a stop or restart never takes the sessions' processes with it
	}
	for w in want do testing.expectf(t, strings.contains(text, w), "missing %q in:\n%s", w, text)
	testing.expect(t, !strings.contains(text, "[Install]"), "never enabled: started on demand only")
}

@(test)
systemd_unit_quoting :: proc(t: ^testing.T) {
	// a home with a space, a quote, a backslash, '%' and '$': each quoted so systemd reads it back
	// as the one path (no specifier, no variable; '$$' only in the arguments, where systemd
	// expands variables)
	text, ok := systemd_unit_text(`/home/a b"c\d%e/serve`, `/r$x`, "/d é")
	testing.expect(t, ok)
	testing.expectf(t, strings.contains(text, `ExecStart="/home/a b\"c\\d%%e/serve" serve --run "/r$$x" --data "/d é"`), "got:\n%s", text)
	// a '$' in the executable is not doubled by systemd's reading: refused
	_, dok := systemd_unit_text("/home/a$b/serve", "/r", "/d")
	testing.expect(t, !dok, "a '$' in the executable's path refused")
	// a line break would end the line: refused
	for bad in ([]string{"/a\nb", "/a\rb", "relative/serve", ""}) {
		_, bok := systemd_unit_text(bad, "/r", "/d")
		testing.expectf(t, !bok, "%q refused", bad)
		_, rok := systemd_unit_text("/s", bad, "/d")
		testing.expectf(t, !rok, "run %q refused", bad)
	}
}

@(test)
systemd_argv_builders :: proc(t: ^testing.T) {
	testing.expect(t, argv_eq(systemd_argv(.Start), {"systemctl", "--user", "--no-ask-password", "start", "deckhand-core.service"}))
	testing.expect(t, argv_eq(systemd_argv(.Reload), {"systemctl", "--user", "--no-ask-password", "daemon-reload"}))
	testing.expect(t, argv_eq(linger_show_argv(1000), {"loginctl", "show-user", "1000", "--property=Linger"}))
	testing.expect(t, argv_eq(linger_enable_argv(), {"loginctl", "--no-ask-password", "enable-linger"}))
	testing.expect_value(t, LINGER_COMMAND, "loginctl enable-linger")
}

@(test)
linger_parse_cases :: proc(t: ^testing.T) {
	cases := []struct {
		out: string,
		ok:  bool,
		want: Linger,
	} {
		{"Linger=yes\n", true, .On},
		{"Linger=no\n", true, .Off},
		{"Linger=no", true, .Off},
		{"Linger=maybe\n", true, .Unknown},
		{"", true, .Unknown},
		{"Linger=yes\n", false, .Unknown}, // loginctl failed: whatever it printed proves nothing
		// a user with no session and no linger has no logind record
		{"Failed to get user: User ID 1000 is not logged in or lingering\n", false, .Off},
		{"Failed to connect to bus: No such file or directory\n", false, .Unknown},
	}
	for c, i in cases do testing.expectf(t, linger_parse(c.out, c.ok) == c.want, "case %d: %v", i, linger_parse(c.out, c.ok))
}

@(private = "file")
argv_eq :: proc(a, b: []string) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

// Only a launch from outside a core (connect, the supervisor) of core/current's binary goes through
// the unit. A running core's handover (or Use previous) launches its bin directly: inside the
// active unit, `systemctl start` would do nothing and the old core's exit would leave none.
@(test)
systemd_start_wanted_cases :: proc(t: ^testing.T) {
	cur := "/h/.local/share/deckhand/core/dev-aaaaaaaaaaaa/deckhand-core-serve"
	testing.expect(t, systemd_start_wanted(bin = cur, current = cur, from_core = false, test_mode = false, unit_there = true, use_previous = false))
	testing.expect(t, !systemd_start_wanted(bin = cur, current = cur, from_core = true, test_mode = false, unit_there = true, use_previous = false), "a handover from a running core")
	testing.expect(t, !systemd_start_wanted(bin = "/h/build/deckhand-core-serve", current = cur, from_core = false, test_mode = false, unit_there = true, use_previous = false), "another binary than current's")
	testing.expect(t, !systemd_start_wanted(bin = cur, current = cur, from_core = false, test_mode = false, unit_there = true, use_previous = true), "Use previous core holds")
	testing.expect(t, !systemd_start_wanted(bin = cur, current = cur, from_core = false, test_mode = true, unit_there = true, use_previous = false), "test mode")
	testing.expect(t, !systemd_start_wanted(bin = cur, current = cur, from_core = false, test_mode = false, unit_there = false, use_previous = false), "no unit")
	testing.expect(t, !systemd_start_wanted(bin = "", current = "", from_core = false, test_mode = false, unit_there = true, use_previous = false), "no current core")
}

@(test)
systemd_scope_cases :: proc(t: ^testing.T) {
	testing.expect(t, argv_eq(systemd_scope_argv("deckhand-holder-0a1b2c3d"), {"/usr/bin/systemd-run", "--user", "--scope", "--quiet", "--collect", "--unit", "deckhand-holder-0a1b2c3d", "--"}))
	testing.expect(t, systemd_scope_wanted(false, false, false))
	testing.expect(t, !systemd_scope_wanted(false, false, true), "DECKHAND_HOLDER_DIRECT: a direct child")
	testing.expect(t, !systemd_scope_wanted(true, false, false), "test mode: direct unless asked")
	testing.expect(t, systemd_scope_wanted(true, true, false))
}
