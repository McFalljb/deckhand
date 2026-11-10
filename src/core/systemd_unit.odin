package core

// The Linux core's systemd user unit and linger (docs/plans/background-core.md §8.4, §10.4
// M6-L2), as pure procs (systemd_unit_test.odin; they run on a Mac too). launch_linux.odin uses
// them: `deckhand-core-serve install` writes the unit and reloads the user manager, `connect`
// starts it when no core answers, and serve reports linger in the hello (machine.linger).
//
// The unit is never enabled: it starts on demand, and the core's idle exit (§6, exit 0) stops it.
// Restart=on-failure restarts a failed core (the holder's supervisor does too, through `launch`),
// except for usage errors (2) and another core already running (3, instance_guard).
// KillMode=process: a stop or restart signals the core alone, never the cgroup. The sessions run
// in the holder's own scope (M6-L3, launch_linux.odin), so they outlive the core either way.

import "core:fmt"
import "core:strings"

SYSTEMD_UNIT :: "deckhand-core.service" // in ~/.config/systemd/user/
LINGER_COMMAND :: "loginctl enable-linger" // what the user runs (shown, never run with sudo)

// The unit's text: serve run from serve (core/current's binary), with run and data. ok false
// when a path is not absolute or has a line break (it would end the line).
systemd_unit_text :: proc(serve, run, data: string, allocator := context.temp_allocator) -> (text: string, ok: bool) {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# Written by `deckhand-core-serve install` (Deckhand), and again by every install.\n")
	// a failing core stops being restarted after 5 starts in a minute (RestartSec alone never
	// trips the default limit); Type=exec: start fails when the binary cannot run, so
	// core_launch falls back to a direct spawn
	strings.write_string(&b, "[Unit]\nDescription=Deckhand core\nStartLimitIntervalSec=60\nStartLimitBurst=5\n\n")
	strings.write_string(&b, "[Service]\nType=exec\nExecStart=")
	for p in ([]string{serve, run, data}) do if !strings.has_prefix(p, "/") || strings.contains_any(p, "\n\r") do return "", false
	if strings.contains_rune(serve, '$') do return "", false // the executable's '$' is not unescaped
	systemd_quote(&b, serve, false)
	strings.write_string(&b, " serve --run ")
	systemd_quote(&b, run, true)
	strings.write_string(&b, " --data ")
	systemd_quote(&b, data, true)
	strings.write_string(&b, "\n")
	// the core asks the login shell for the user's environment (login_env.odin), as under launchd
	strings.write_string(&b, "Environment=DECKHAND_GUI_LAUNCH=1\n")
	strings.write_string(&b, "Restart=on-failure\nRestartSec=2\nRestartPreventExitStatus=2 3\n")
	strings.write_string(&b, "KillMode=process\n")
	return strings.to_string(b), true
}

// One ExecStart word, double-quoted, byte by byte: '\\' and '"' escaped, '%' (a specifier)
// doubled, and in an argument (arg: where systemd expands variables) '$' doubled.
@(private = "file")
systemd_quote :: proc(b: ^strings.Builder, s: string, arg: bool) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\', '"': strings.write_byte(b, '\\')
		case '%': strings.write_byte(b, '%')
		case '$': if arg do strings.write_byte(b, '$')
		}
		strings.write_byte(b, s[i])
	}
	strings.write_byte(b, '"')
}

Systemd_Op :: enum {
	Reload, // daemon-reload, after the unit is written
	Start, // the core's unit
}

// systemctl's argv for op: the user manager, never a password prompt.
systemd_argv :: proc(op: Systemd_Op) -> []string {
	@(static, rodata) reload := [?]string{"systemctl", "--user", "--no-ask-password", "daemon-reload"}
	@(static, rodata) start := [?]string{"systemctl", "--user", "--no-ask-password", "start", SYSTEMD_UNIT}
	switch op {
	case .Reload: return reload[:]
	case .Start:  return start[:]
	}
	return nil
}

Linger :: enum u8 {
	Unknown, // no logind, or its answer unreadable: nothing is said
	On,
	Off, // jobs on this machine stop when the user logs out of it
}

// `loginctl show-user UID --property=Linger` (the uid: no name to quote).
linger_show_argv :: proc(uid: u32, allocator := context.temp_allocator) -> []string {
	a := make([]string, 4, allocator)
	a[0], a[1], a[2], a[3] = "loginctl", "show-user", fmt.aprintf("%d", uid, allocator = allocator), "--property=Linger"
	return a
}

// The caller's own linger, with no prompt: polkit allows it or refuses (no sudo, ever).
linger_enable_argv :: proc() -> []string {
	@(static, rodata) argv := [?]string{"loginctl", "--no-ask-password", "enable-linger"}
	return argv[:]
}

// linger_show_argv's output (stderr merged), ok: it exited 0. A user with neither a session nor
// linger has no logind record: off.
linger_parse :: proc(out: string, ok: bool) -> Linger {
	if !ok do return strings.contains(out, "is not logged in or lingering") ? .Off : .Unknown
	switch strings.trim_space(out) {
	case "Linger=yes": return .On
	case "Linger=no":  return .Off
	}
	return .Unknown
}

// Whether core_launch goes through the unit: only a launch from outside a core (connect, the
// supervisor; not a running core's handover, whose successor would be a second process in the
// active unit, where `systemctl start` does nothing), of core/current's binary (bin and current
// resolved), with the unit there, Use previous core not holding, and not in test mode. Else bin
// is launched directly, as macOS's launchd fallback does.
systemd_start_wanted :: proc(bin, current: string, from_core, test_mode, unit_there, use_previous: bool) -> bool {
	return !from_core && !test_mode && unit_there && !use_previous && current != "" && bin == current
}

// ---- transient scopes (M6-L3) ----
//
// The holder, and a core started directly (a handover's successor, a launch with no unit), each
// run in a transient scope of their own: `systemd-run --user --scope … -- <bin> …`. systemd-run
// moves itself into the new scope and execs the rest, so the pid spawned is the holder's (or the
// core's), outside the launcher's cgroup: stopping deckhand-core.service never reaches it, and a
// successor core is no longer left in a unit that went inactive. --collect: the scope goes once
// its processes do, failed or not.

SYSTEMD_RUN :: "/usr/bin/systemd-run"

// systemd-run's argv before the command, for a scope named unit (".scope" is added by systemd).
systemd_scope_argv :: proc(unit: string, allocator := context.temp_allocator) -> []string {
	a := make([]string, 8, allocator)
	a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7] = SYSTEMD_RUN, "--user", "--scope", "--quiet", "--collect", "--unit", unit, "--"
	return a
}

// Whether a launch goes through a scope: always outside test mode (unless DECKHAND_HOLDER_DIRECT
// asks for a direct child); in test mode only when DECKHAND_HOLDER_SYSTEMD asks for it.
systemd_scope_wanted :: proc(test_mode, hook_systemd, hook_direct: bool) -> bool {
	if test_mode do return hook_systemd
	return !hook_direct
}

// Whether args may go on systemd-run's command line (scope_launch).
systemd_scope_args_ok :: proc(args: []string) -> bool {return true}
