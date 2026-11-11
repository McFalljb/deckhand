package core

// Other machines as the user sees them (machines.odin): the add field's target and name, the
// plain status words (the sidebar, Settings and tooltips share them), the statuses that wait for
// the user (no retry on a timer), Rename and Remove. No ssh runs.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(test)
machines_ux_target_and_name :: proc(t: ^testing.T) {
	// what people paste: a leading `ssh ` or `ssh://` (and a trailing /) is dropped
	testing.expect_value(t, machine_target_clean("  ssh jb@nuc.home.arpa "), "jb@nuc.home.arpa")
	testing.expect_value(t, machine_target_clean("ssh://jb@nuc/"), "jb@nuc")
	testing.expect_value(t, machine_target_clean("SSH nuc"), "nuc")
	testing.expect_value(t, machine_target_clean("sshbox"), "sshbox")
	// a bad target says what is allowed, with an example
	testing.expect_value(t, machine_target_plain_error("jb@nuc"), "")
	for bad in ([?]string{"", "jb@nuc -p 22", "-oProxyCommand=x", "a;b", "$(id)"}) {
		w := machine_target_plain_error(bad)
		testing.expectf(t, w != "" && strings.contains(w, "like jb@nuc.local"), "%q: %q", bad, w)
	}
	testing.expect(t, strings.contains(machine_target_plain_error("jb@nuc -p 22"), "Type only the machine"), "options")
	// the default name: the host part, never upper-cased; an alias as it is; an IP whole
	testing.expect_value(t, machine_default_name("jb@nuc.home.arpa"), "nuc")
	testing.expect_value(t, machine_default_name("studio-mac-mini.local"), "studio-mac-mini")
	testing.expect_value(t, machine_default_name("nuc"), "nuc")
	testing.expect_value(t, machine_default_name("jb@192.168.1.5"), "192.168.1.5")
	testing.expect_value(t, machine_default_name("Lab-Box"), "Lab-Box")
	// a name: one line, bounded
	testing.expect_value(t, machine_name_clean("  my\tbox‮ "), "my box")
	testing.expect(t, len(machine_name_clean(strings.repeat("é", 50, context.temp_allocator))) <= 64, "64 bytes at most, whole runes")
}

@(test)
machines_ux_status_words :: proc(t: ^testing.T) {
	// the hub door closed there: refused (waits for the user), not offline
	s, _ := machine_status_of({replied = true, ok = false, error = HUB_NOT_ALLOWED})
	testing.expect_value(t, s, Machine_Status.Refused)
	for w in ([?]Machine_Status{.Needs_Login, .Refused, .Unsupported}) do testing.expectf(t, machine_status_waits_for_user(w), "%v waits for the user", w)
	for w in ([?]Machine_Status{.Offline, .Needs_Update, .Not_Installed, .Taken, .Online, .Connecting}) do testing.expectf(t, !machine_status_waits_for_user(w), "%v does not", w)
	// no status id reaches the user
	for st in Machine_Status {
		label, why, _ := machine_status_text({name = "nuc", target = "jb@nuc", status = st})
		testing.expectf(t, label != "" && !strings.contains(label, "_") && !strings.contains(why, "_"), "%v: %q %q", st, label, why)
		for word in ([?]string{"core", "hub", "generation", "linger", "mux"}) do testing.expectf(t, !strings.contains(strings.to_lower(why, context.temp_allocator), word), "%v: %q says %s", st, why, word)
	}
	Case :: struct {
		m:              Machine_View,
		label, why, raw: string,
	}
	cases := []Case {
		{{target = "jb@nuc-typo", status = .Offline, error = "ssh: Could not resolve hostname nuc-typo: nodename nor servname provided, or not known"}, "offline", "Can't find a computer called nuc-typo", "ssh: Could not resolve hostname nuc-typo: nodename nor servname provided, or not known"},
		{{target = "nuc", status = .Offline, error = "ssh: connect to host nuc port 22: Connection refused"}, "offline", "It refused the connection", "ssh: connect to host nuc port 22: Connection refused"},
		{{target = "nuc", status = .Offline, error = "ssh: connect to host nuc port 22: Operation timed out"}, "offline", "The connection timed out", "ssh: connect to host nuc port 22: Operation timed out"},
		{{target = "nuc", status = .Offline, error = "kex_exchange_identification: read: Connection reset by peer"}, "offline", "The connection failed", "kex_exchange_identification: read: Connection reset by peer"},
		{{target = "nuc", status = .Offline, error = "no answer from its core"}, "offline", "Deckhand there did not answer", ""},
		{{target = "nuc", status = .Needs_Login, error = "jb@nuc: Permission denied (publickey)."}, "needs you to log in", "ssh wants a password or a key: Log in…", "jb@nuc: Permission denied (publickey)."},
		{{target = "nuc", status = .Refused, error = HUB_NOT_ALLOWED}, "not allowed", "Turn on Allow other machines to connect on that Mac", ""},
		{{target = "nuc", status = .Unsupported, error = "FreeBSD amd64"}, "not supported", "Not a Mac or Linux machine", "FreeBSD amd64"},
		{{target = "nuc", status = .Taken, error = "viewed from Studio"}, "in use there", "Shown from Studio now: Take back shows it here", ""},
		{{target = "nuc", status = .Needs_Update, error = "its core is newer: update Deckhand on this Mac"}, "needs an update", "Its Deckhand is newer than this Mac's: update Deckhand on this Mac", ""},
		{{target = "nuc", status = .Not_Installed, job = .Failed, job_note = "tar: Write error"}, "install failed", "Install failed: it could not write the files there (is its disk full?)", "tar: Write error"},
		{{target = "nuc", status = .Not_Installed, job = .Failed, job_note = "scp: write: No space left on device"}, "install failed", "Install failed: its disk is full", "scp: write: No space left on device"},
		{{target = "nuc", status = .Not_Installed, job = .Failed, job_note = "rsync: something odd"}, "install failed", "Install failed: the copy there did not work", "rsync: something odd"},
		{{target = "nuc", status = .Not_Installed, job = .Failed, job_note = "cancelled"}, "no Deckhand there", "Deckhand isn't installed there: Install…", ""},
		{{target = "nuc", status = .Not_Installed, job = .Copying}, "installing…", "", ""},
		{{target = "nuc", status = .Not_Installed, job = .Failed, job_note = "installed, but its core refused this Mac: x"}, "install failed", "Install failed: it is installed, but it does not allow other machines to connect: turn on Allow other machines to connect there", ""},
	}
	for c, i in cases {
		label, why, raw := machine_status_text(c.m)
		testing.expectf(t, label == c.label && why == c.why && raw == c.raw, "case %d: %q %q %q", i, label, why, raw)
	}
	// the buttons: Retry after a failed install; never Connect where it cannot work
	testing.expect_value(t, machine_action_label({status = .Not_Installed, job = .Failed, job_note = "tar: Write error"}), "Retry")
	testing.expect_value(t, machine_action_label({status = .Refused}), "")
	testing.expect_value(t, machine_action_label({status = .Unsupported}), "")
	testing.expect_value(t, machine_action_label({status = .Needs_Login}), "Log in…")
	testing.expect_value(t, machine_action_label({status = .Offline}), "Connect")
}

when TEST_HOOKS {

@(private = "file")
Ux_Fixture :: struct {
	dir:        string,
	saved_root: string,
	saved_sep, saved_on: bool,
}

@(private = "file")
ux_up :: proc() -> (f: Ux_Fixture) {
	base := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if base == "" do base = "/tmp"
	f.dir = fmt.aprintf("%s/dkux-%d-%d", base, posix.getpid(), time.now()._nsec % 1_000_000_000)
	f.saved_root, f.saved_sep, f.saved_on = home_root, core_separate, state.settings.remote_machines
	home_root = fmt.aprintf("%s/data", f.dir)
	os.make_directory_all(home_root)
	core_separate, state.settings.remote_machines = true, true
	machines_load()
	return
}

@(private = "file")
ux_down :: proc(f: ^Ux_Fixture) {
	machines_reset_for_test()
	remove_tree(f.dir)
	home_root, core_separate, state.settings.remote_machines = f.saved_root, f.saved_sep, f.saved_on
}

// What the add field takes: the cleaned target, a short name, no second copy. The links never
// start here (no tick): no ssh runs.
@(test)
machines_ux_add_rename_remove :: proc(t: ^testing.T) {
	f := ux_up()
	defer ux_down(&f)
	r := machine_add_apply({target = "ssh jb@nuc.home.arpa"})
	testing.expect(t, r.ok, r.error)
	a := r.created_id
	fa, _ := machine_facts(a)
	testing.expect(t, fa.name == "nuc" && fa.target == "jb@nuc.home.arpa", fa.name)
	r = machine_add_apply({target = "ssh://jb2@nuc.lan/"})
	testing.expect(t, r.ok, r.error)
	fb, _ := machine_facts(r.created_id)
	testing.expect(t, fb.name == "jb2@nuc.lan" && fb.target == "jb2@nuc.lan", "a second nuc: its whole target")
	r = machine_add_apply({target = "jb@nuc.home.arpa"})
	testing.expect(t, !r.ok && strings.contains(r.error, "already in your machines"), r.error)
	r = machine_add_apply({target = "jb@nuc x"})
	testing.expect(t, !r.ok && strings.contains(r.error, "Type only the machine"), r.error)
	// Rename: the name only, cleaned; the target stays; a taken name is refused
	r = machine_rename_apply({no = a, name = "  Lab\tbox "})
	testing.expect(t, r.ok, r.error)
	fa, _ = machine_facts(a)
	testing.expect(t, fa.name == "Lab box" && fa.target == "jb@nuc.home.arpa", fa.name)
	r = machine_rename_apply({no = a, name = "JB2@NUC.LAN"})
	testing.expect(t, !r.ok && strings.contains(r.error, "already called"), r.error)
	saved, _, _ := machines_read(machines_path(), context.temp_allocator)
	testing.expect(t, len(saved) == 2 && saved[0].name == "Lab box" && saved[0].target == "jb@nuc.home.arpa", "saved")
	// Remove asks first; the user's yes removes it
	rr, _ := machine_remove_apply({no = a}, {kind = .UI})
	testing.expect(t, !rr.ok && rr.error == "needs_confirmation" && strings.has_prefix(rr.confirm_summary, "Remove Lab box from Deckhand? Nothing on it is deleted"), rr.confirm_summary)
	_, still := machine_facts(a)
	testing.expect(t, still, "not removed before the yes")
	rr, _ = machine_remove_apply({no = a, confirm = rr.confirm_token}, {kind = .UI})
	testing.expect(t, rr.ok, rr.error)
	_, still = machine_facts(a)
	testing.expect(t, !still, "removed")
}

// Needs-login, refused and unsupported never retry on the timer (a failed login a minute could
// trip fail2ban there); offline does; the user's Connect or an edit tries again.
@(test)
machines_ux_no_retry :: proc(t: ^testing.T) {
	f := ux_up()
	defer ux_down(&f)
	r := machine_add_apply({name = "m2", via = "true"})
	testing.expect(t, r.ok, r.error)
	no := r.created_id
	testing.expect(t, machine_outcome_for_test(no, {exited = true, exit_code = 255, stderr = "jb@nuc: Permission denied (publickey)."}), "needs_login waits")
	testing.expect(t, machine_outcome_for_test(no, {replied = true, ok = false, error = HUB_NOT_ALLOWED}), "refused waits")
	testing.expect(t, !machine_outcome_for_test(no, {exited = true, exit_code = 255, stderr = "ssh: connect to host nuc port 22: Connection refused"}), "offline retries")
	machine_outcome_for_test(no, {replied = true, ok = false, error = HUB_NOT_ALLOWED})
	testing.expect(t, !machine_retries_for_test(no), "refused: nothing runs")
	testing.expect(t, machine_connect_apply({no = no}).ok, "Connect")
	testing.expect(t, machine_retries_for_test(no), "the user's Connect tries again")
	machine_outcome_for_test(no, {replied = true, ok = false, error = HUB_NOT_ALLOWED})
	testing.expect(t, machine_rename_apply({no = no, name = "m3"}).ok, "rename")
	testing.expect(t, machine_retries_for_test(no), "an edit tries again")
}

} // when TEST_HOOKS

// Allow other machines to connect: turning it on asks first, with the warning; off does not.
@(test)
machines_ux_reachable_asks :: proc(t: ^testing.T) {
	saved := state.settings.machines_reachable
	defer state.settings.machines_reachable = saved
	state.settings.machines_reachable = false
	r := run_command(Set_Machines_Reachable{on = true}, {kind = .UI})
	testing.expect(t, !r.ok && r.error == "needs_confirmation" && strings.contains(r.confirm_summary, "Allow only machines you trust as yourself"), r.confirm_summary)
	testing.expect(t, !state.settings.machines_reachable, "not on before the yes")
	r = run_command(Set_Machines_Reachable{on = true, confirm = r.confirm_token}, {kind = .UI})
	testing.expect(t, r.ok && state.settings.machines_reachable, r.error)
	r = run_command(Set_Machines_Reachable{on = false}, {kind = .UI})
	testing.expect(t, r.ok && !state.settings.machines_reachable, "off at once")
}
