package core

// Other machines over SSH (docs/plans/background-core.md §8, §10.4 M6-A): the registry, the link
// to each machine's core and its status. Behind Settings › Machines over SSH
// (remote_machines_default_on: on since M6-F, an opt-out). Only a separate core
// (deckhand-core-serve serve) runs links, and only to the machines the user added: with none,
// nothing runs (no ssh, no process).
//
// The registry is <data>/machines.json (0600): {"next":N,"machines":[{no, name, target, os, arch,
// core_path, via?}]}. Numbers come from `next`, 1-8191, never reused (M6-B packs them into ids).
// every machine_* command is this Mac's user's only (who = .User_Here: never from a hub); `via` (a
// command run in place of `ssh … connect`) is taken only in development and test builds.
//
// The link: the user's own `ssh` (their ~/.ssh/config: the target is an alias or user@host, never
// edited), run with argv only, never through a local shell:
//   ssh -S <run>/ssh-<n>.ctl -o ControlMaster=auto -o ControlPersist=600 -o BatchMode=yes
//       -o Compression=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -- <target>
//       '"$HOME/<core path>" connect --from <this Mac> --core <this core's id>'
// on a socketpair: its stdin and stdout are one end, the transport (src/corewire) the other; its
// stderr is a pipe, read for why it failed. The remote command is one of two constant paths plus
// this Mac's name in [A-Za-z0-9._-] (machine_from_name) and this core's id (hex: the other end
// refuses a core that is its own hub), so nothing typed reaches the remote shell. A machine whose
// OS is not known yet is asked first (`uname -sm`, the same ssh; ≤ 30 s). `deckhand-core-serve
// connect` on the other end says the hub hello (window_sock.odin) and copies bytes; its hello
// reply is the first JSON line on the link (lines before it, a remote rc file's, are skipped),
// read here through skew_check. Its version and error, and a hub.taken's name, are another
// machine's text: State carries them cleaned (text_clean: printable, no bidi controls, bounded).
// Bytes past a cap with no answer end the attempt at once.
//
// Caps from the first byte: the remote core treats the hub as its window, so it sends what a
// window would act on. Every window.request (clipboard, open_url, notify, reveal, pick_folder…)
// and confirmation.parked from a hub link is dropped here, unread, and never acted on (§8.3).
//
// Its state (M6-B): once online the link sends state.subscribe, and the other core's state.full
// and state.delta go into a replica of its State (state_read.odin: bounded decode), merged into
// this core's State (machine_mirror.odin). A replica that refuses a message asks for state.full
// again. Down, the merged entries stay as last seen (the sidebar greys them); up again, a fresh
// state.full replaces them. Selecting one of its projects here sends it select_project, so its
// sessions come. The user's commands on its ids, and its terminals, go through machine_route.odin
// (M6-C): their results, term.attached, term.scroll and its terminal channels' frames are read
// here and handed there; nothing else is taken.
//
// Reconnects back off: 1 s, doubling to 60 s, back to 1 s after a minute up. A link the other
// machine's own window took back (hub.taken) waits for the user's Take back (machine_connect).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import cw "../corewire"
import jg "../jsonguard"

// Settings › Machines over SSH: on by default since M6-F (an opt-out; with no machine added it
// starts nothing).
remote_machines_default_on := true

Set_Remote_Machines :: struct {
	on: bool,
}

// Settings › Machines › Allow other machines to connect to this one: the hub door
// (window_sock.odin). Off by default, and separate from Machines over SSH (which reaches out):
// on, another machine's core that logs in here over ssh as this user can view and drive this
// machine's sessions. User-only. A Linux core's install over ssh turns it on there (M6-E).
machines_reachable_default_on :: false

Set_Machines_Reachable :: struct {
	on:      bool,
	confirm: string, // turning it on: the user confirms first (MACHINES_REACH_QUESTION)
}

// What turning Allow other machines to connect on asks first (the guide's warning, plainly).
MACHINES_REACH_QUESTION :: "Allow other machines to connect to this Mac? A machine you allow acts as you on this Mac: it can see and drive its sessions, type into its shells and prompt its agents. Allow only machines you trust as yourself."
// Adds a machine: target (an ~/.ssh/config alias or user@host; a leading `ssh ` or `ssh://` is
// dropped), name (what Deckhand calls it; "": the target's host part, machine_default_name);
// via: a development or test build's command in place of `ssh … connect`. User-only.
Machine_Add :: struct {
	name, target, via: string,
}
// Removes a machine (the user confirms first: nothing on it is touched). User-only.
Machine_Remove :: struct {
	no:      u64,
	confirm: string,
}
// Renames a machine: only what Deckhand calls it; its ssh target stays. User-only.
Machine_Rename :: struct {
	no:   u64,
	name: string,
}
// Connect now: Take back from that machine's window, or retry without waiting. User-only.
Machine_Connect :: struct {
	no: u64,
}
// Log in… (needs_login): a shell tab here runs `ssh -M` to it in the foreground, so its password,
// host key or 2FA prompt is answered in a real terminal; the link then uses that master. User-only.
Machine_Login :: struct {
	no: u64,
}

MACHINE_NO_CORE :: "no Deckhand core at its path" // a Not_Installed link's error (machine_status_of)

Machine_Status :: enum u8 {
	Connecting,
	Online,
	Offline,
	Needs_Login, // ssh wanted a password, a host key or 2FA (BatchMode): Log in… (M6-B)
	Needs_Update, // its core is below CORE_MIN or another generation
	Not_Installed, // no core at its path
	Taken, // that machine's own window (or another hub) took it back
	Refused, // its Deckhand does not let other machines connect (its Allow other machines… is off)
	Unsupported, // not a Mac or Linux (uname -sm)
}

// Statuses only the user can fix: no retry on a timer (a failed login every minute could trip
// fail2ban there), only on the user's Connect, Log in…, or an edit (machine_rename).
machine_status_waits_for_user :: proc(s: Machine_Status) -> bool {
	return s == .Needs_Login || s == .Refused || s == .Unsupported
}

// A machine as State's `machines` section carries it (Settings › Machines).
Machine_View :: struct {
	no:      u64,
	name:    string,
	target:  string,
	status:  Machine_Status,
	version: string, // its core's release version ("" = a development build, or not known)
	os:      string, // "darwin", "linux" ("" = not known yet)
	arch:    string,
	error:   string, // why it is not online
	job:       Machine_Job, // its install or update (machine_install.odin)
	job_note:  string, // what that said (cleaned)
	update:    Update_Offer, // Update on its row (machine_update_offer)
	linger:    Linger, // Linux: its hello's machine.linger (Unknown: not said)
	checklist: []Machine_Check, // its coding agents, as its core's checklist says (read-only here)
	core_run:  string, // its core's run id (its hello's `core`; "" = not known): a restart there changes it
	codex:     bool, // its hello's features list codex_tabs: Codex tabs may be started there (machine_route.odin)
}

// One row of another machine's coding agents checklist (its core's live.checklist, cleaned).
Machine_Check :: struct {
	id:      string, // a HARNESS_MANIFEST id this build knows
	state:   Harness_Item_State,
	command: string, // what the user runs there (Copy; "" = nothing to do)
}

MACHINE_CHECKS_MAX :: 16
MACHINE_CHECK_COMMAND_MAX :: 512

// One registry entry (machines.json).
Machine :: struct {
	no:        u64,
	name:      string,
	target:    string,
	os:        string,
	arch:      string,
	core_path: string, // "~/…" (MACHINE_CORE_PATHS), from os
	via:       string,
}

MACHINES_FILE :: "machines.json"
MACHINE_NO_MAX :: 8191
MACHINE_CTL_MAX :: 86 // sun_path's 104, less ssh's ".<16 random>" temporary name and the NUL
MACHINE_BACKOFF_MIN :: time.Second
MACHINE_BACKOFF_MAX :: 60 * time.Second
MACHINE_UP_RESET :: 60 * time.Second // up this long: the next drop waits MACHINE_BACKOFF_MIN again
MACHINE_HELLO_WAIT :: 30 * time.Second // connect may launch a core (15 s) first
MACHINE_PROBE_WAIT :: 30 * time.Second
MACHINE_DRAIN_WAIT :: 10 * time.Second // an older core told to hand over: its link closes by then
MACHINE_STDERR_MAX :: 4096 // also the probe's output's cap
MACHINE_HELLO_MAX :: 1 << 20 // the bytes before the hello reply's newline
MACHINE_VERSION_MAX :: 64 // State's version and error from another machine (text_clean)
MACHINE_ERROR_MAX :: 128

// Where a machine's core is, by its OS (its own data dir's core/current, §8.4).
MACHINE_CORE_PATHS := [?][2]string {
	{"darwin", "~/Library/Application Support/Deckhand/core/current/Deckhand Core.app/Contents/MacOS/deckhand-core-serve"},
	{"linux", "~/.local/share/deckhand/core/current/deckhand-core-serve"},
}

machine_core_path_for :: proc(os_name: string) -> string {
	for p in MACHINE_CORE_PATHS do if p[0] == os_name do return p[1]
	return ""
}

// ---- names ----

// Why a machine's name cannot be used ("" = it can).
machine_name_error :: proc(name: string) -> string {
	if strings.trim_space(name) == "" do return "a machine needs a name"
	if len(name) > 64 do return "a machine's name has at most 64 bytes"
	for r in name do if r < 0x20 || r == 0x7f do return "a machine's name cannot hold control characters"
	return ""
}

// Why an ssh target cannot be used ("" = it can): an ~/.ssh/config alias, host, user@host or
// user@host:port-free form, in [A-Za-z0-9._@:-], never starting with '-' (an ssh option).
machine_target_error :: proc(target: string) -> string {
	if target == "" do return "a machine needs a target (an ~/.ssh/config alias or user@host)"
	if len(target) > 255 do return "the target is too long"
	if target[0] == '-' do return "a target cannot start with -"
	for c in transmute([]u8)target {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' || c == '@' || c == ':'
		if !ok do return "a target holds only letters, digits and . _ - @ :"
	}
	if machine_target_has_port(target) do return MACHINE_PORT_ERROR
	return ""
}

MACHINE_PART_ERROR :: "Type both sides of user@host, like me@nuc.local"

// user@, @host, a@@b, host: — a side of the @, or the port after one trailing :, left empty (an
// IPv6 address's :: is whole). The add field's check only (machine_target_plain_error): a target
// saved before is never refused for it at connect.
machine_target_part_missing :: proc(target: string) -> bool {
	if strings.has_prefix(target, "@") || strings.has_suffix(target, "@") || strings.contains(target, "@@") do return true
	return strings.has_suffix(target, ":") && !strings.has_suffix(target, "::")
}

MACHINE_PORT_ERROR :: "To use another port, add a Host entry to ~/.ssh/config and type its name here."

// host:2222 (one colon, digits after it): ssh would read it all as the host's name. An IPv6
// address has more colons.
machine_target_has_port :: proc(target: string) -> bool {
	i := strings.last_index_byte(target, ':')
	if i < 0 || i == len(target) - 1 || strings.count(target, ":") != 1 do return false
	for c in transmute([]u8)target[i + 1:] do if c < '0' || c > '9' do return false
	return true
}

// This Mac's name as the hub hello says it (Viewed from <machine>): the host name without
// ".local", in [A-Za-z0-9._-], at most 64 bytes (it rides in the remote command's argv).
machine_from_name :: proc(host: string) -> string {
	h := strings.trim_suffix(host, ".local")
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)h {
		if strings.builder_len(b) >= 64 do break
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'
		strings.write_byte(&b, ok ? c : '-')
	}
	s := strings.to_string(b)
	return s == "" ? "mac" : s
}

// ---- the ssh argv ----

machine_ctl_path :: proc(run: string, no: u64) -> string {
	return fmt.tprintf("%s/ssh-%d.ctl", strings.trim_right(run, "/"), no)
}

// How an ssh of ours reaches a machine (ssh_argv).
Ssh_Mode :: enum u8 {
	Master, // the link (probe and connect): -S <ctl>, ControlMaster=auto, ControlPersist=600
	Mux, // a one-off command (M6-E's install, its cleanup, linger): rides the link's master on
	// <ctl> (no new login: a password user's Log in… master too); never a master itself, and a
	// fresh connection when no master is up
	Forward, // a web page's own connection (machine_page.odin): no master, no ControlPath, only its -L
}

// Every ssh this core runs (temp allocator). The options come before the user's config (ssh takes
// the first value it is given): never in the background (a config's ForkAfterAuthentication would
// leave our process group), no tty, never a prompt, no agent or X11 forwarding, no LocalCommand,
// keepalives; no forwards at all but a page's own -L (ClearAllForwardings). extra: options after
// those (a page's -N -L, the link's Compression). The target is checked (machine_target_error) and
// goes after `--`, then the remote command (one fixed string of ours, "" = none).
ssh_argv :: proc(target: string, mode: Ssh_Mode, ctl := "", extra: []string = nil, remote := "") -> (argv: []string, why: string) {
	if w := machine_target_error(target); w != "" do return nil, w
	if mode != .Forward {
		if ctl == "" do return nil, "no control socket for ssh"
		if len(ctl) > MACHINE_CTL_MAX do return nil, fmt.tprintf("ssh's control socket %s is longer than %d bytes", ctl, MACHINE_CTL_MAX)
	}
	out := make([dynamic]string, context.temp_allocator)
	append(&out, "ssh")
	switch mode {
	case .Master:  append(&out, "-S", ctl, "-o", "ControlMaster=auto", "-o", "ControlPersist=600")
	case .Mux:     append(&out, "-S", ctl, "-o", "ControlMaster=no", "-o", "ControlPersist=no")
	case .Forward: append(&out, "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no")
	}
	append(&out, "-o", "ForkAfterAuthentication=no", "-o", "RequestTTY=no", "-o", "BatchMode=yes")
	if mode == .Forward do append(&out, "-o", "ClearAllForwardings=no", "-o", "ExitOnForwardFailure=no")
	else do append(&out, "-o", "ClearAllForwardings=yes")
	append(&out, "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4")
	for e in extra do append(&out, e)
	append(&out, "--", target)
	if remote != "" do append(&out, remote)
	return out[:], ""
}

// What runs for machine m: `ssh … <target> 'uname -sm'` (probe) or `ssh … connect`, or its via
// command (development and test builds only). argv[0] is looked up on PATH. Temp allocator.
// core_id: this core's (hex, window_door_core_id; "" = none sent).
machine_argv :: proc(m: Machine, run, from: string, core_id := "", probe := false, test_build := TEST_HOOKS) -> (argv: []string, why: string) {
	out := make([dynamic]string, context.temp_allocator)
	if core_id != "" && !hex64_ok(core_id) do return nil, "this core's id is not hex"
	if m.via != "" {
		if !test_build do return nil, "via is only for development and test builds"
		for f in strings.fields(m.via, context.temp_allocator) do append(&out, f)
		if len(out) == 0 do return nil, "via is empty"
		append(&out, "--from", machine_from_name(from))
		if core_id != "" do append(&out, "--core", core_id)
		return out[:], ""
	}
	if w := machine_target_error(m.target); w != "" do return nil, w
	remote: string
	if probe {
		remote = "uname -sm"
	} else {
		want := machine_core_path_for(m.os)
		if want == "" || m.core_path != want do return nil, "this machine's core path is not one Deckhand knows"
		remote = fmt.tprintf(`"$HOME/%s" connect --from %s`, want[2:], machine_from_name(from))
		if core_id != "" do remote = fmt.tprintf("%s --core %s", remote, core_id)
	}
	return ssh_argv(m.target, .Master, machine_ctl_path(run, m.no), {"-o", "Compression=yes"}, remote)
}

// `uname -sm`'s answer as Odin names it (the hello reply's machine{os, arch}).
machine_uname_parse :: proc(text: string) -> (os_name, arch: string, ok: bool) {
	f := strings.fields(strings.trim_space(text), context.temp_allocator)
	if len(f) != 2 do return "", "", false
	switch f[0] {
	case "Darwin": os_name = "darwin"
	case "Linux":  os_name = "linux"
	case:          return "", "", false
	}
	switch f[1] {
	case "arm64", "aarch64": arch = "arm64"
	case "x86_64", "amd64":  arch = "amd64"
	case:                    return "", "", false
	}
	return os_name, arch, true
}

// The hello reply's machine{os, arch}, taken only when both are values `uname -sm` gives here
// (machine_uname_parse: darwin|linux, arm64|amd64); else the old ones (another machine's text never
// reaches State or machines.json, nor makes its core path one Deckhand does not know).
machine_os_arch_from_hello :: proc(os_name, arch, old_os, old_arch: string) -> (string, string) {
	os_ok := os_name == "darwin" || os_name == "linux"
	arch_ok := arch == "arm64" || arch == "amd64"
	if !os_ok || !arch_ok do return old_os, old_arch
	return os_name, arch
}

// The probe's answer: the first line `uname -sm` could have printed (a remote rc file's lines
// before it are skipped).
machine_probe_answer :: proc(text: string) -> (os_name, arch: string, ok: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if o, a, lok := machine_uname_parse(line); lok do return o, a, true
	}
	return "", "", false
}

Machine_Scan :: enum u8 {
	Wait, // no answer yet
	Found,
	Too_Long, // cap bytes and no answer: the attempt ends now (its fd would stay readable)
}

// The hello reply in buf: the first whole line that is a JSON object (lines before it skipped);
// rest: where the frames start.
machine_hello_scan :: proc(buf: []u8, cap: int) -> (s: Machine_Scan, line: string, rest: int) {
	text := string(buf)
	at := 0
	for {
		nl := strings.index_byte(text[at:], '\n')
		if nl < 0 do break
		l := strings.trim_space(text[at:at + nl])
		if strings.has_prefix(l, "{") do return .Found, l, at + nl + 1
		at += nl + 1
	}
	return len(buf) >= cap ? .Too_Long : .Wait, "", 0
}

// ---- the status table ----

// What one attempt came to.
Machine_Outcome :: struct {
	replied:   bool, // a hello reply came
	ok:        bool, // ...and it said ok
	error:     string, // its error
	skew:      cw.Skew,
	exited:    bool, // the process ended (before a reply)
	exit_code: int,
	stderr:    string,
	up:        bool, // the link was online in this attempt (then it dropped): never a login's
}

machine_status_of :: proc(o: Machine_Outcome) -> (s: Machine_Status, why: string) {
	if o.replied {
		if !o.ok && strings.contains(o.error, "does not let other machines connect") do return .Refused, o.error // HUB_NOT_ALLOWED
		if !o.ok do return .Offline, o.error
		switch o.skew {
		case .Ok, .Core_Older:      return .Online, ""
		case .Core_Below_Min:       return .Needs_Update, "its core is older than this Mac's can work with"
		case .Core_Older_Generation: return .Needs_Update, "its core is from an older generation"
		case .Core_Newer_Generation: return .Needs_Update, "its core is newer: update Deckhand on this Mac"
		}
	}
	last := machine_last_line(o.stderr)
	// a login's failure is ssh's last word, before the link came up; a link that was up and then
	// dropped is offline (a prompt's words earlier in its output do not count): it retries
	if o.exited && o.exit_code == 255 && !o.up {
		for p in ([?]string{"Permission denied", "Host key verification failed", "password", "passphrase", "keyboard-interactive"}) {
			if strings.contains(last, p) do return .Needs_Login, last
		}
	}
	if o.exited && (o.exit_code == 127 || o.exit_code == 126) do return .Not_Installed, MACHINE_NO_CORE
	return .Offline, last != "" ? last : "the connection ended"
}

// ---- what the user reads (the sidebar, Settings and their tooltips: one place) ----

// A machine's status in plain words: label (a few words, in sentence case like a session's "Waiting
// for you": the sidebar's header, Settings' row, the Jobs tab), why (a sentence that says what is
// wrong; "" = nothing to say; it never points at the button next to it, which says that) and raw
// (the text it came from, ssh's or the install's, cleaned: a tooltip's second line; "" = none). Temp.
machine_status_text :: proc(m: Machine_View) -> (label, why, raw: string) {
	// its install or update: while it runs, then a failure that still applies
	if m.job != .None && m.job != .Done && m.job != .Failed do return fmt.tprintf("%s…", sentence_case(MACHINE_JOB_NAMES[m.job])), "", ""
	if machine_install_failed(m) {
		w, r := machine_install_why(m.job_note)
		what := m.update != .None ? "Update" : "Install"
		return fmt.tprintf("%s failed", what), fmt.tprintf("%s failed: %s", what, w), r
	}
	// an update that has to be made on that machine: no button here, the sentence says what to do
	if m.update == .Command_Only do return m.status == .Online ? "Online" : "Needs an update", "Its Deckhand wasn't installed by Deckhand: update it on that machine", ""
	switch m.status {
	case .Connecting:    return "Connecting…", "", ""
	case .Online:
		if m.linger == .Off do return "Online", "Its jobs stop when you log out of it: Keep running… keeps them going", ""
		return "Online", "", ""
	case .Offline:
		why, raw = machine_offline_why(m.error, m.target != "" ? m.target : m.name)
		return "Offline", why, raw
	case .Needs_Login:   return "Needs you to log in", "ssh wants a password or a key", m.error
	case .Needs_Update:
		if strings.contains(m.error, "newer") do return "Needs an update", "Its Deckhand is newer than this Mac's: update Deckhand on this Mac", ""
		return "Needs an update", "Its Deckhand is too old for this Mac", ""
	case .Not_Installed:
		// its add's install could not start: why (mlink_down), else the plain fact
		if m.error != "" && m.error != MACHINE_NO_CORE do return "No Deckhand there", fmt.tprintf("Deckhand isn't installed there. %s", sentence_case(m.error)), ""
		return "No Deckhand there", "Deckhand isn't installed there", ""
	case .Taken:
		if strings.has_prefix(m.error, "viewed from ") do return "In use there", fmt.tprintf("Shown from %s now: Take back shows it here", m.error[len("viewed from "):]), ""
		return "In use there", "Its own window is showing it: Take back shows it here", ""
	case .Refused:       return "Not allowed", "Turn on Allow other machines to connect on that machine", ""
	case .Unsupported:   return "Not supported", "Not a Mac or Linux machine", m.error
	}
	return "", "", ""
}

// s with its first letter upper-case (ASCII; temp).
@(private = "file")
sentence_case :: proc(s: string) -> string {
	if s == "" || s[0] < 'a' || s[0] > 'z' do return s
	return fmt.tprintf("%c%s", rune(s[0] - 32), s[1:])
}

// A failed install or update that still applies (its machine has no Deckhand, or one to update);
// one the user cancelled is not.
machine_install_failed :: proc(m: Machine_View) -> bool {
	return m.job == .Failed && m.job_note != "cancelled" && (m.status == .Not_Installed || m.update != .None)
}

// Why an install failed, in plain words, and the note it came from when that was a program's
// (tar, scp: a tooltip's second line). Temp.
machine_install_why :: proc(note: string) -> (why, raw: string) {
	has :: proc(s: string, any: ..string) -> bool {
		for a in any do if strings.contains(s, a) do return true
		return false
	}
	switch {
	case note == "":                                           return "it stopped", ""
	case has(note, "No space left", "Disk quota"):             return "its disk is full", note
	case has(note, "Write error", "Cannot write", "cannot write"): return "it could not write the files there (is its disk full?)", note
	case has(note, "Permission denied"):                       return "it was not allowed to write the files there", note
	case has(note, "link went down"):                          return "the connection dropped", ""
	case has(note, "refused this Mac"):                        return "it is installed, but it does not allow other machines to connect: turn on Allow other machines to connect there", ""
	case has(note, "timed out", "took over"):                  return "it took too long", ""
	}
	// a program's own words ("tar: …", "scp: …"): say it plainly, keep them for the tooltip
	if i := strings.index(note, ": "); i > 0 && i < 24 && !strings.contains(note[:i], " ") do return "the copy there did not work", note
	return note, ""
}

// Why a machine is offline, in plain words (the common ssh failures as a sentence), and ssh's own
// line when the sentence came from it. host: what it is reached as (its target, else its name). Temp.
machine_offline_why :: proc(err, host: string) -> (why, raw: string) {
	has :: proc(s: string, any: ..string) -> bool {
		for a in any do if strings.contains(s, a) do return true
		return false
	}
	h := host
	if i := strings.last_index_byte(h, '@'); i >= 0 do h = h[i + 1:]
	switch {
	case err == "":                                                              return "", "" // its label says Offline
	case has(err, "Could not resolve hostname", "nodename nor servname", "Name or service not known"): return fmt.tprintf("Can't find a computer called %s", text_clean(h, 64)), err
	case has(err, "Connection refused"):                                          return "It refused the connection", err
	case has(err, "timed out"):                                                   return "The connection timed out", err
	case has(err, "No route to host", "Network is unreachable", "Host is down"):  return "Can't reach it on the network", err
	case has(err, "Machines over SSH is off"):                                    return "Machines over SSH is off", ""
	case has(err, "no answer from its core", "no answer to uname"):               return "Deckhand there did not answer", ""
	case has(err, "connecting again after the install"):                          return "Connecting again after the install", ""
	case err == "the connection ended":                                           return "The connection ended", ""
	}
	return "The connection failed", err
}

machine_last_line :: proc(text: string) -> string {
	t := strings.trim_space(text)
	if i := strings.last_index_byte(t, '\n'); i >= 0 do t = t[i + 1:]
	return strings.trim_space(t)
}

// ---- backoff ----

Machine_Backoff :: struct {
	delay:    time.Duration, // the next wait (0: MACHINE_BACKOFF_MIN)
	up_since: time.Tick, // {}: not up
}

machine_backoff_up :: proc(b: ^Machine_Backoff, now: time.Tick) {b.up_since = now}

// The link went down (or an attempt failed): how long to wait before the next.
machine_backoff_down :: proc(b: ^Machine_Backoff, now: time.Tick) -> time.Duration {
	if b.up_since != {} && time.tick_diff(b.up_since, now) >= MACHINE_UP_RESET do b.delay = 0
	b.up_since = {}
	wait := b.delay > 0 ? b.delay : MACHINE_BACKOFF_MIN
	b.delay = min(wait * 2, MACHINE_BACKOFF_MAX)
	return wait
}

// ---- the registry ----

machines_path :: proc() -> string {
	if home_root == "" do return ""
	return fmt.tprintf("%s/%s", strings.trim_right(home_root, "/"), MACHINES_FILE)
}

// Reads path ("" or missing: none). Strings in allocator.
machines_read :: proc(path: string, allocator := context.allocator) -> (list: [dynamic]Machine, next: u64, ok: bool) {
	list = make([dynamic]Machine, allocator)
	next = 1
	b, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return list, next, !os.exists(path)
	v, jerr := jg.parse_string(string(b), .JSON, true, context.temp_allocator)
	if jerr != nil do return list, next, false
	obj, is := v.(json.Object)
	if !is do return list, next, false
	if n, nok := obj["next"].(json.Integer); nok && n >= 1 && n <= MACHINE_NO_MAX + 1 do next = u64(n)
	arr, _ := obj["machines"].(json.Array)
	str :: proc(o: json.Object, k: string, a: runtime.Allocator) -> string {
		s, _ := o[k].(json.String)
		return strings.clone(s, a)
	}
	for e in arr {
		o, eok := e.(json.Object)
		if !eok do continue
		no, nok := o["no"].(json.Integer)
		if !nok || no < 1 || no > MACHINE_NO_MAX do continue
		m := Machine{no = u64(no), name = str(o, "name", allocator), target = str(o, "target", allocator), os = str(o, "os", allocator), arch = str(o, "arch", allocator), core_path = str(o, "core_path", allocator), via = str(o, "via", allocator)}
		append(&list, m)
		if m.no >= next do next = m.no + 1
	}
	return list, next, true
}

// Writes the registry, 0600, through a temp file and a rename. "" = written.
machines_write :: proc(path: string, list: []Machine, next: u64) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"next":%d,"machines":[`, next)
	for m, i in list {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"no":%d`, m.no)
		for kv in ([?][2]string{{"name", m.name}, {"target", m.target}, {"os", m.os}, {"arch", m.arch}, {"core_path", m.core_path}}) {
			fmt.sbprintf(&b, `,"%s":`, kv[0])
			json_quote(&b, kv[1])
		}
		if m.via != "" {
			strings.write_string(&b, `,"via":`)
			json_quote(&b, m.via)
		}
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}\n")
	text := strings.to_string(b)
	tmp := fmt.tprintf("%s.new", path)
	os.remove(tmp)
	fd := posix.open(strings.clone_to_cstring(tmp, context.temp_allocator), {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 do return fmt.tprintf("cannot write %s", tmp)
	ok := posix.write(fd, raw_data(text), uint(len(text))) == len(text)
	posix.close(fd)
	if !ok || posix.rename(strings.clone_to_cstring(tmp, context.temp_allocator), strings.clone_to_cstring(path, context.temp_allocator)) != 0 {
		os.remove(tmp)
		return fmt.tprintf("cannot write %s", path)
	}
	return ""
}

// ---- the links (main thread) ----

@(private = "file")
Mach_Phase :: enum u8 {
	Idle, // waiting for next_at
	Probe, // uname -sm
	Hello, // connect runs: waiting for its hello reply line
	Up, // frames
	Stopped, // taken, removed, or the setting is off: no retry
	Draining, // an older core's hello got core_handover (M6-E): nothing more is sent or read until it closes (≤ MACHINE_DRAIN_WAIT)
}

@(private = "file")
Mach_Link :: struct {
	using m:   Machine, // heap strings
	phase:     Mach_Phase,
	status:    Machine_Status,
	version:   string, // heap
	error:     string, // heap
	pid:       posix.pid_t,
	fd:        posix.FD, // our end of the socketpair (-1: none)
	err_fd:    posix.FD, // the child's stderr (-1: none)
	errbuf:    [dynamic]u8,
	inbuf:     [dynamic]u8, // a probe's output, or the bytes before the hello reply's newline
	started:   time.Tick,
	next_at:   time.Tick,
	backoff:   Machine_Backoff,
	sock:      ^cw.Sock_Transport,
	exit_code: int,
	exited:    bool,
	replica:   State, // heap: its State as its core last sent it (state_read.odin)
	mirror:    Machine_Mirror, // what of it is merged into State (machine_mirror.odin)
	merged:    bool, // its entries are in State
	stream:    Mirror_Stream, // its state stream's bounds (machine_mirror.odin)
	skew:      cw.Skew, // its last hello's
	installed: bool, // its last hello said its core runs from Deckhand's own folder (M6-E)
	core_run:  string, // heap: its last hello's run id (`core`; "" = an older core's, none)
	codex:     bool, // its last hello's features list codex_tabs
	linger:   Linger, // its last hello's machine.linger (Linux), or what linger --enable said
	auto_install: bool, // added by the user: its first attempt's finding of no core starts an install (M6-E); any status but connecting clears it (mlink_set)
	install_why: string, // heap: why that install could not start (its note while it has no core: machine_status_text); "" = none
	drain_skew: cw.Skew, // Draining: the hello's
	login_until: time.Tick, // Log in… ran: while its control socket is not there yet (≤ MACHINE_LOGIN_WAIT), looked for once a second; there, the link connects
}

MACHINE_LOGIN_WAIT :: 10 * time.Minute

@(private = "file")
mach: struct {
	links:  [dynamic]^Mach_Link,
	next:   u64,
	loaded: bool,
	from:   string, // heap: this Mac's name (machine_from_name)
	arena:  virtual.Arena, // what state.machines points into
	dropped: int, // window.request and confirmation.parked dropped from hub links (tests, logs)
}

when TEST_HOOKS {
	// Tests (machine_route_test.odin): machine links with no process; what is sent on them, kept.
	Machine_Test_Frame :: struct {
		no:      u64,
		channel: u32,
		kind:    cw.Kind,
		payload: []u8, // heap
	}
	machine_test_links: struct {
		on:     bool,
		up:     map[u64]bool,
		texts:  [dynamic]string, // heap
		frames: [dynamic]Machine_Test_Frame,
	}
}

when TEST_HOOKS {
	// Tests (machine_install_test.odin): a link's status as its last attempt left it.
	machine_status_set_for_test :: proc(no: u64, s: Machine_Status, version := "", installed := false, skew := cw.Skew.Ok) {
		l, _ := mlink_find(no)
		if l == nil do return
		l.installed, l.skew = installed, skew
		delete(l.version, runtime.heap_allocator())
		l.version = strings.clone(version, runtime.heap_allocator())
		mlink_set(l, s, "")
		l.phase = .Stopped // no attempt runs in a test
	}
	// mlink_hello on a socketpair with line as the reply: what it sent (its JSON frames, joined).
	machine_hello_for_test :: proc(no: u64, line: string) -> string {
		l, _ := mlink_find(no)
		if l == nil do return ""
		fds: [2]posix.FD
		if posix.socketpair(.UNIX, .STREAM, .IP, &fds) != .OK do return ""
		posix.fcntl(fds[1], .SETFL, posix.fcntl(fds[1], .GETFL) | posix.O_NONBLOCK)
		l.fd, l.phase = fds[0], .Hello
		mlink_hello(l, line, nil)
		heap := runtime.heap_allocator()
		peer: cw.Sock_Transport
		cw.sock_open(&peer, fds[1], allocator = heap)
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< 64 {
			f, err := cw.sock_recv(&peer, context.temp_allocator)
			if err != .None do break
			if f.channel == cw.JSON_CHANNEL do fmt.sbprintln(&b, string(f.payload))
		}
		cw.sock_destroy(&peer) // closes fds[1]
		mlink_close(l)
		l.phase = .Stopped
		return strings.to_string(b)
	}
	// The probe exited with code and out: as the tick takes it.
	machine_probe_for_test :: proc(no: u64, out: string, code: int) {
		l, _ := mlink_find(no)
		if l == nil do return
		clear(&l.inbuf)
		append(&l.inbuf, ..transmute([]u8)out)
		l.phase, l.exited, l.exit_code = .Probe, true, code
		mlink_probe_done(l, time.tick_now())
		if l.phase == .Idle do l.phase = .Stopped
	}
	// mlink_down with outcome o (a finished attempt). waits: it waits for the user (no retry on
	// the timer), as mlink_down left it; then no attempt runs in a test either way.
	machine_outcome_for_test :: proc(no: u64, o: Machine_Outcome, up := false) -> (waits: bool) {
		if l, _ := mlink_find(no); l != nil {
			if up do l.phase = .Up // it was online, then this
			mlink_down(l, o)
			waits = l.phase == .Stopped
			l.phase = .Stopped
		}
		return
	}
	// Machine no's link would try again on its own (its timer, or a login's socket), or waits.
	machine_retries_for_test :: proc(no: u64) -> bool {
		l, _ := mlink_find(no)
		return l != nil && (l.phase == .Idle || l.login_until != {})
	}
	machines_reset_for_test :: proc() {
		for l in mach.links do mlink_free(l)
		clear(&mach.links)
		mach.loaded = false
	}
}

// Machine no's link is online (machine_route.odin).
machine_link_up :: proc(no: u64) -> bool {
	when TEST_HOOKS do if machine_test_links.on do return machine_test_links.up[no]
	l, _ := mlink_find(no)
	return l != nil && l.phase == .Up && l.sock != nil
}

// An install's core_handover on machine no's up link (machine_install.odin's copy_done).
machine_handover_send :: proc(no: u64) -> bool {
	name := ""
	if l, _ := mlink_find(no); l != nil do name = l.name
	return machine_link_send_text(no, machine_handover_text(name))
}

// A JSON message on machine no's link (false: not online, or it refused it).
machine_link_send_text :: proc(no: u64, text: string) -> bool {
	when TEST_HOOKS do if machine_test_links.on {
		if !machine_test_links.up[no] do return false
		append(&machine_test_links.texts, strings.clone(text, runtime.heap_allocator()))
		return true
	}
	l, _ := mlink_find(no)
	return l != nil && mlink_send(l, text)
}

// A frame on one of machine no's terminal channels.
machine_link_send_frame :: proc(no: u64, channel: u32, kind: cw.Kind, payload: []u8) -> bool {
	when TEST_HOOKS do if machine_test_links.on {
		if !machine_test_links.up[no] do return false
		p := make([]u8, len(payload), runtime.heap_allocator())
		copy(p, payload)
		append(&machine_test_links.frames, Machine_Test_Frame{no = no, channel = channel, kind = kind, payload = p})
		return true
	}
	l, _ := mlink_find(no)
	if l == nil || l.sock == nil || l.phase != .Up || channel == cw.JSON_CHANNEL do return false
	if cw.sock_send(l.sock, channel, kind, payload) != .None do return false
	cw.sock_flush(l.sock)
	return true
}

// Machine no's registry entry (machine_page.odin), its strings the link's.
machine_entry :: proc(no: u64) -> (Machine, bool) {
	l, _ := mlink_find(no)
	if l == nil do return {}, false
	return l.m, true
}

// Dropped from hub links so far (tests).
machines_dropped :: proc() -> int {return mach.dropped}

// At serve's start (home_root set): the registry, this Mac's name, the machines section.
machines_load :: proc() {
	heap := runtime.heap_allocator()
	list, next, ok := machines_read(machines_path(), heap)
	if !ok do log_ln("Deckhand: machines.json could not be read: no machines until it is fixed or removed")
	mach.next = next
	mach.links = make([dynamic]^Mach_Link, heap)
	for m in list {
		l := new(Mach_Link, heap)
		l.m = m
		l.fd, l.err_fd = -1, -1
		append(&mach.links, l)
	}
	delete(list)
	host: [256]u8
	name := "mac"
	if posix.gethostname(&host[0], len(host) - 1) == .OK do name = string(cstring(&host[0]))
	mach.from = strings.clone(machine_from_name(name), heap)
	mach.loaded = ok
	machine_install_leftovers() // an earlier run's install downloads (machine_install.odin)
	machines_publish()
}

// This machine's name, as it gives itself to other machines (machine_from_name; the sidebar's and
// the Jobs tab's header over its own rows): the core's (a replica's live section) or this process's.
machine_here_name :: proc() -> string {
	if replica_process do return state.live.machine != "" ? state.live.machine : "mac"
	if mach.from != "" do return mach.from
	host: [256]u8
	name := "mac"
	if posix.gethostname(&host[0], len(host) - 1) == .OK do name = string(cstring(&host[0]))
	return machine_from_name(name)
}

// The machines section, from the links (after any change a window should see).
@(private = "file")
machines_publish :: proc() {
	virtual.arena_free_all(&mach.arena)
	a := virtual.arena_allocator(&mach.arena)
	views := make([dynamic]Machine_View, 0, len(mach.links), a)
	for l in mach.links {
		job, note := machine_install_view(l.no)
		v := Machine_View{no = l.no, name = strings.clone(l.name, a), target = strings.clone(l.target, a), status = l.status, version = strings.clone(l.version, a), os = strings.clone(l.os, a), arch = strings.clone(l.arch, a), error = strings.clone(l.error, a), job = job, job_note = strings.clone(note, a), linger = l.linger, core_run = strings.clone(l.core_run, a), codex = l.codex}
		v.update = machine_update_offer(core_version(), l.version, l.status, l.skew, l.installed)
		v.checklist = machine_checks_of(&l.replica, a)
		append(&views, v)
	}
	state.machines = views[:]
	window_state_changed()
}

// Another machine's checklist (its replica's live.checklist), as this Mac shows it: ids this
// build knows, at most MACHINE_CHECKS_MAX, commands cleaned and capped (another machine's text).
machine_checks_of :: proc(r: ^State, a: runtime.Allocator) -> []Machine_Check {
	out := make([dynamic]Machine_Check, 0, min(len(r.live.checklist), MACHINE_CHECKS_MAX), a)
	for c in r.live.checklist {
		if len(out) >= MACHINE_CHECKS_MAX do break
		if _, known := harness_row(c.id); !known do continue
		append(&out, Machine_Check{id = strings.clone(c.id, a), state = c.state, command = strings.clone(text_clean(c.command, MACHINE_CHECK_COMMAND_MAX), a)})
	}
	return out[:]
}

// The machines section again (machine_install.odin: a job's phase changed).
machines_changed :: proc() {if mach.loaded || mach.links != nil do machines_publish()}

// What machine_install.odin reads of a machine's link (its strings the link's).
Machine_Facts :: struct {
	name, target, os, arch, version, core_run: string,
	via:       bool,
	status:    Machine_Status,
	skew:      cw.Skew,
	installed: bool,
}

machine_facts :: proc(no: u64) -> (f: Machine_Facts, ok: bool) {
	l, _ := mlink_find(no)
	if l == nil do return {}, false
	return {name = l.name, target = l.target, os = l.os, arch = l.arch, version = l.version, core_run = l.core_run, via = l.via != "", status = l.status, skew = l.skew, installed = l.installed}, true
}

// Connect again now (after an install: its next hello says what runs there).
machine_reconnect_now :: proc(no: u64) {
	l, _ := mlink_find(no)
	if l == nil || l.phase == .Stopped && l.status == .Taken do return
	if l.phase == .Up do mlink_down(l, {stderr = "connecting again after the install"})
	else if l.phase != .Idle do mlink_close(l)
	l.phase, l.next_at, l.backoff = .Idle, {}, {}
}

// linger --enable said on (machine_install.odin).
machine_linger_set :: proc(no: u64, v: Linger) {
	l, _ := mlink_find(no)
	if l == nil do return
	l.linger = v
	machines_publish()
}

@(private = "file")
machines_save :: proc() -> string {
	path := machines_path()
	if path == "" do return "no data dir"
	list := make([dynamic]Machine, context.temp_allocator)
	for l in mach.links do append(&list, l.m)
	return machines_write(path, list[:], mach.next)
}

@(private = "file")
mlink_set :: proc(l: ^Mach_Link, s: Machine_Status, why := "") {
	heap := runtime.heap_allocator()
	if s != .Connecting do l.auto_install = false // the attempt after the user's add ended, whatever it found
	if l.status == s && l.error == why do return
	l.status = s
	delete(l.error, heap)
	l.error = strings.clone(text_clean(why, MACHINE_ERROR_MAX), heap) // another machine's text (its error, ssh's stderr, a hub.taken's name)
	if autotest_active do fmt.printfln("[autotest] machine %s: %s%s%s", l.name, MACHINE_STATUS_NAMES[s], why != "" ? ": " : "", why)
	machines_publish()
}

MACHINE_STATUS_NAMES := [Machine_Status]string {
	.Connecting    = "connecting",
	.Online        = "online",
	.Offline       = "offline",
	.Needs_Login   = "needs_login",
	.Needs_Update  = "needs_update",
	.Not_Installed = "not_installed",
	.Taken         = "taken",
	.Refused       = "refused",
	.Unsupported   = "unsupported",
}

// Ends what runs for l: its process group gets SIGTERM and the tick reaps it, or (wait) SIGKILL and
// it is reaped here.
@(private = "file")
mlink_close :: proc(l: ^Mach_Link, wait := false) {
	heap := runtime.heap_allocator()
	if l.sock != nil {
		cw.sock_destroy(l.sock) // closes l.fd
		free(l.sock, heap)
		l.sock = nil
		l.fd = -1
	}
	if l.fd >= 0 do posix.close(l.fd)
	if l.err_fd >= 0 do posix.close(l.err_fd)
	l.fd, l.err_fd = -1, -1
	if l.pid > 0 && !l.exited {
		posix.kill(-l.pid, wait ? .SIGKILL : .SIGTERM) // waiting: it must go now
		if wait {
			st: i32
			for posix.waitpid(l.pid, &st, {}) < 0 && posix.errno() == .EINTR {}
			l.exited = true
		}
	}
	clear(&l.inbuf)
	clear(&l.errbuf)
}

// The link ended without a hub.taken: a status from what it came to, then a wait (backoff).
@(private = "file")
mlink_down :: proc(l: ^Mach_Link, o: Machine_Outcome) {
	was_up := l.phase == .Up
	o := o
	o.up = o.up || was_up
	s, why := machine_status_of(o)
	auto := l.auto_install // mlink_set clears it
	mlink_close(l)
	machine_route_down(l.no) // what waited for it ends; its terminals attach again when it is up
	page_forwards_drop(l.no) // its web pages' forwards (machine_page.odin)
	if was_up do machine_install_link_down(l.no) // an update started on it ends (machine_install.odin)
	l.phase = .Idle
	l.next_at = time.tick_add(time.tick_now(), machine_backoff_down(&l.backoff, time.tick_now()))
	if machine_status_waits_for_user(s) do l.phase, l.backoff = .Stopped, {} // until the user's Connect, Log in… or an edit
	// added by the user and no core there: its install starts, once (machine_install.odin); when it
	// cannot, why is its note (plain words) while it still has no core, not only stderr
	heap := runtime.heap_allocator()
	if s != .Not_Installed {
		delete(l.install_why, heap)
		l.install_why = ""
	}
	mlink_set(l, s, l.install_why != "" ? l.install_why : why)
	if s == .Not_Installed && auto && state.settings.remote_machines {
		if r := machine_install_start(l.no); !r.ok {
			log_ln("Deckhand: machine", l.name, "install:", r.error)
			delete(l.install_why, heap)
			l.install_why = strings.clone(r.error, heap)
			mlink_set(l, s, l.install_why)
		}
	}
}

// Why an install could not start no longer holds (machine_install.odin): machine no's note goes
// (an install of it started or was cancelled), or with no = 0 every machine's note that said too
// many installs were running (one ended). Its status says the plain fact again.
machine_install_why_clear :: proc(no: u64) {
	heap := runtime.heap_allocator()
	for l in mach.links {
		if l.install_why == "" do continue
		if no != 0 ? l.no != no : !strings.has_suffix(l.install_why, INSTALLS_BUSY) do continue
		delete(l.install_why, heap)
		l.install_why = ""
		if l.status == .Not_Installed do mlink_set(l, .Not_Installed, MACHINE_NO_CORE)
	}
}

// Starts l's probe or connect. False: it could not start (status set, retried later).
@(private = "file")
mlink_start :: proc(l: ^Mach_Link) {
	run, rwhy := sock_runtime_dir_why(context.temp_allocator)
	probe := l.via == "" && l.os == ""
	argv, why := machine_argv(l.m, run, mach.from, window_door_core_id(), probe)
	if rwhy != "" do why = rwhy
	if why != "" {
		l.phase = .Stopped // a bad entry or a release build's via: nothing to retry
		mlink_set(l, .Offline, why)
		return
	}
	if l.pid > 0 && !l.exited { // the last attempt's process did not go on SIGTERM: it goes now
		posix.kill(-l.pid, .SIGKILL)
		st: i32
		for posix.waitpid(l.pid, &st, {}) < 0 && posix.errno() == .EINTR {}
		l.exited = true
	}
	pid, fd, efd, ok := machine_spawn(argv)
	if !ok {
		mlink_down(l, {exited = true, exit_code = -1, stderr = fmt.tprintf("cannot run %s", argv[0])})
		return
	}
	l.pid, l.fd, l.err_fd, l.exited, l.exit_code = pid, fd, efd, false, 0
	l.phase = probe ? .Probe : .Hello
	l.started = time.tick_now()
	if autotest_active do fmt.printfln("[autotest] machine %s: %s", l.name, probe ? "probe" : "connect")
	// a retry on the timer leaves the machine's status as it is (its row keeps its button, and
	// does not flicker); the first try, and the user's (its backoff reset), say connecting
	if l.backoff.delay == 0 do mlink_set(l, .Connecting)
}

// Spawns argv (looked up on PATH) in its own process group: stdin and stdout one end of a
// socketpair (fd, ours: nonblocking), stderr a pipe (efd, ours: nonblocking). Nothing else of
// ours reaches it.
@(private = "file")
machine_spawn :: proc(argv: []string) -> (pid: posix.pid_t, fd, efd: posix.FD, ok: bool) {
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	sp: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, .IP, &sp) != .OK do return 0, -1, -1, false
	ep: [2]posix.FD
	if posix.pipe(&ep) != .OK {
		posix.close(sp[0]); posix.close(sp[1])
		return 0, -1, -1, false
	}
	for x in ([4]posix.FD{sp[0], sp[1], ep[0], ep[1]}) do posix.fcntl(x, .SETFD, i32(posix.FD_CLOEXEC))
	attr, fa: [512]u8
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	posix_spawnattr_setflags(&attr, i16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
	posix_spawnattr_setpgroup(&attr, 0)
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	posix_spawn_file_actions_adddup2(&fa, i32(sp[1]), 0)
	posix_spawn_file_actions_adddup2(&fa, i32(sp[1]), 1)
	posix_spawn_file_actions_adddup2(&fa, i32(ep[1]), 2)
	sync.rw_mutex_shared_lock(&fork_lock)
	err := posix.posix_spawnp(&pid, cargv[0], &fa, &attr, raw_data(cargv), posix.environ)
	sync.rw_mutex_shared_unlock(&fork_lock)
	posix.close(sp[1])
	posix.close(ep[1])
	if err != .NONE {
		posix.close(sp[0]); posix.close(ep[0])
		return 0, -1, -1, false
	}
	for x in ([2]posix.FD{sp[0], ep[0]}) do posix.fcntl(x, .SETFL, posix.fcntl(x, .GETFL) | posix.O_NONBLOCK)
	return pid, sp[0], ep[0], true
}

// The fds the core loop polls for the links (into out; returns how many).
machines_poll_fds :: proc(out: []posix.pollfd) -> int {
	n := 0
	for l in mach.links {
		if n >= len(out) do break
		if l.fd < 0 do continue
		ev: posix.Poll_Event = {.IN}
		if l.sock != nil && cw.sock_wants_write(l.sock) do ev += {.OUT}
		out[n] = {fd = l.fd, events = ev}
		n += 1
	}
	return n
}

// The core loop's turn: start what is due, read what came, reap what ended. Main thread.
machines_tick :: proc() {
	if !mach.loaded && mach.links == nil do return
	on := state.settings.remote_machines && core_separate
	now := time.tick_now()
	if !on do machine_install_drop(0) // its installs end (machine_install.odin)
	for l in mach.links {
		if !on { // the setting went off: every link ends; turned on again, each starts afresh
			if l.phase != .Idle || l.fd >= 0 do mlink_close(l)
			mlink_reap(l)
			mlink_unmerge(l)
			machine_route_down(l.no, gone = true) // what waited for it, its terminals (machine_route.odin)
			page_forwards_drop(l.no)
			l.phase, l.next_at, l.backoff = .Idle, {}, {}
			mlink_set(l, .Offline, "Machines over SSH is off")
			continue
		}
		mlink_reap(l)
		switch l.phase {
		case .Stopped:
			// after Log in…: connect once its login's control socket is there (no attempt before:
			// each would be a failed login there)
			if l.login_until != {} && time.tick_diff(l.next_at, now) >= 0 {
				l.next_at = time.tick_add(now, time.Second)
				if time.tick_diff(l.login_until, now) >= 0 {
					l.login_until = {}
				} else if run, rwhy := sock_runtime_dir_why(context.temp_allocator); rwhy == "" {
					st: posix.stat_t
					if posix.stat(strings.clone_to_cstring(machine_ctl_path(run, l.no), context.temp_allocator), &st) == .OK {
						l.login_until = {}
						l.phase, l.next_at, l.backoff = .Idle, {}, {}
					}
				}
			}
		case .Idle:
			if l.next_at == {} || time.tick_diff(l.next_at, now) >= 0 do mlink_start(l)
		case .Probe:
			mlink_read_err(l)
			mlink_read_raw(l, MACHINE_STDERR_MAX)
			if len(l.inbuf) >= MACHINE_STDERR_MAX {
				mlink_down(l, {stderr = "too much output for uname -sm"})
			} else if !l.exited && time.tick_diff(l.started, now) > MACHINE_PROBE_WAIT {
				mlink_down(l, {stderr = "no answer to uname -sm"})
			} else if l.exited {
				mlink_probe_done(l, now)
			}
		case .Hello:
			mlink_read_err(l)
			mlink_read_raw(l, MACHINE_HELLO_MAX)
			if s, line, rest := machine_hello_scan(l.inbuf[:], MACHINE_HELLO_MAX); s == .Found {
				mlink_hello(l, line, l.inbuf[rest:])
			} else if s == .Too_Long {
				mlink_down(l, {stderr = "too much output and no answer from its core"})
			} else if l.exited { // its stdout's EOF alone waits for the exit: the exit code says why
				mlink_down(l, {exited = true, exit_code = l.exit_code, stderr = string(l.errbuf[:])})
			} else if time.tick_diff(l.started, now) > MACHINE_HELLO_WAIT {
				mlink_down(l, {stderr = "no answer from its core"})
			}
		case .Draining:
			mlink_read_err(l)
			gone := false
			if _, err := cw.sock_flush(l.sock); err != .None do gone = true
			for _ in 0 ..< 256 {
				if gone do break
				runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
				_, err := cw.sock_recv(l.sock, context.temp_allocator)
				if err == .Closed do gone = true
				if err != .None do break
			}
			if gone || time.tick_diff(l.started, now) > MACHINE_DRAIN_WAIT do mlink_down(l, {replied = true, ok = true, skew = l.drain_skew})
		case .Up:
			mlink_read_err(l)
			mlink_pump(l)
			if l.phase == .Up && mirror_stream_due(&l.stream, now) do mlink_send(l, window_msg_subscribe()) // a refused full: asked again
		}
	}
	machine_route_tick(now)
	machine_install_tick(now) // installs and updates: their children and checks (machine_install.odin)
	page_forwards_tick(now) // web pages: their ssh children, tabs and requests (machine_page.odin)
}

// The probe (uname -sm) exited: its OS and arch kept and the connect next, or a status.
@(private = "file")
mlink_probe_done :: proc(l: ^Mach_Link, now: time.Tick) {
	if os_name, arch, ok := machine_probe_answer(string(l.inbuf[:])); ok && l.exit_code == 0 {
		heap := runtime.heap_allocator()
		delete(l.os, heap); delete(l.arch, heap); delete(l.core_path, heap)
		l.os, l.arch, l.core_path = strings.clone(os_name, heap), strings.clone(arch, heap), strings.clone(machine_core_path_for(os_name), heap)
		if w := machines_save(); w != "" do log_ln("Deckhand: machines:", w)
		mlink_close(l)
		l.phase = .Idle
		l.next_at = now
	} else if l.exit_code == 0 {
		l.phase = .Stopped
		uname := strings.clone(machine_last_line(string(l.inbuf[:])), context.temp_allocator) // mlink_close clears inbuf
		mlink_close(l)
		mlink_set(l, .Unsupported, uname)
	} else do mlink_down(l, {exited = true, exit_code = l.exit_code, stderr = string(l.errbuf[:])})
}

// Whether a hello reply's result.data.features lists name (exactly; no list: no).
hello_feature :: proc(line, name: string) -> bool {
	n, ok := strconv.parse_int(json_path(line, "result.data.features.#")) // a list (json_path's guarded parse)
	if !ok do return false
	for i in 0 ..< min(n, 32) do if json_path(line, fmt.tprintf("result.data.features.%d", i)) == name do return true
	return false
}

// The hello reply line came: online (frames from here on) or a status.
@(private = "file")
mlink_hello :: proc(l: ^Mach_Link, line: string, rest: []u8) {
	o := Machine_Outcome{replied = true}
	o.ok = json_path(line, "result.ok") == "true" && json_path(line, "result.data.framed") == "true"
	if !o.ok {
		o.error = json_path(line, "result.error")
		if o.error == "" || o.error == "<invalid json>" do o.error = "its core did not take the hub"
		machine_install_refused(l.no, o.error) // an install's new core that refuses this Mac (its setting off)
		mlink_down(l, o)
		return
	}
	gen, _ := strconv.parse_i64(json_path(line, "result.data.generation"))
	version := text_clean(json_path(line, "result.data.version"), MACHINE_VERSION_MAX)
	run := json_path(line, "result.data.core")
	if !hex64_ok(run) do run = "" // an older core's (none) or not an id
	// what this hello says of its core, whatever its status: kept here, the one place
	codex := hello_feature(line, FEATURE_CODEX_TABS) // an older core's: none
	heap := runtime.heap_allocator()
	if version != l.version || run != l.core_run || codex != l.codex {
		delete(l.version, heap); delete(l.core_run, heap)
		l.version, l.core_run, l.codex = strings.clone(version, heap), strings.clone(run, heap), codex
		machines_publish()
	}
	o.skew = cw.skew_check(cw.GENERATION, gen, core_version(), version)
	l.skew = o.skew
	l.installed = json_path(line, "result.data.machine.installed") == "true" // absent (an older core): false
	switch json_path(line, "result.data.machine.linger") {
	case "true":  l.linger = .On
	case "false": l.linger = .Off
	case:         l.linger = .Unknown
	}
	// an install's handover (machine_install.odin): an older core of Deckhand's own gets
	// core_handover{current} on this link, as the user's, once
	handover := machine_install_hello(l.no, l.core_run, l.installed)
	s, why := machine_status_of(o)
	if s != .Online {
		if handover {
			// the link stays open until that core quits (its frames are dropped unread), so the
			// command reaches it from a live peer; then the status as the hello said
			l.sock = new(cw.Sock_Transport, heap)
			cw.sock_open(l.sock, l.fd, initial = rest, allocator = heap)
			clear(&l.inbuf)
			cw.sock_send(l.sock, cw.JSON_CHANNEL, .Data, transmute([]u8)machine_handover_text(l.name))
			cw.sock_flush(l.sock)
			l.phase, l.started, l.drain_skew = .Draining, time.tick_now(), o.skew
			return
		}
		mlink_down(l, o)
		return
	}
	if mos, march := machine_os_arch_from_hello(json_path(line, "result.data.machine.os"), json_path(line, "result.data.machine.arch"), l.os, l.arch); mos != l.os || march != l.arch {
		mos, march = strings.clone(mos, heap), strings.clone(march, heap)
		delete(l.os, heap); delete(l.arch, heap)
		l.os, l.arch = mos, march
	}
	l.sock = new(cw.Sock_Transport, heap)
	cw.sock_open(l.sock, l.fd, initial = rest, allocator = heap)
	clear(&l.inbuf)
	l.phase = .Up
	machine_backoff_up(&l.backoff, time.tick_now())
	mlink_set(l, .Online, why)
	l.stream = {want_full = true} // deltas wait for its first state.full
	mlink_send(l, window_msg_subscribe()) // its state (M6-B): state.full, then deltas
	if id_machine(state.selected_project) == l.no do mlink_send(l, hub_command_json(Select_Project{project_id = id_local(state.selected_project)}, "", .UI))
	machine_route_up(l.no) // the window's terminals of it attach again, each from a fresh snapshot (machine_route.odin)
	if handover do mlink_send(l, machine_handover_text(l.name)) // a compatible older core of Deckhand's own: the same handover
}

// Sends one JSON message on an online link (false: not sent; the link's pump finds out why).
@(private = "file")
mlink_send :: proc(l: ^Mach_Link, text: string) -> bool {
	if l.sock == nil || l.phase != .Up do return false
	if cw.sock_send(l.sock, cw.JSON_CHANNEL, .Data, transmute([]u8)text) != .None do return false
	cw.sock_flush(l.sock)
	return true
}

// Its state message into the replica, then into State. A message the replica refuses: state.full
// again (subscribing again sends it).
@(private = "file")
mlink_state :: proc(l: ^Mach_Link, text: string, full: bool) {
	now := time.tick_now()
	switch mirror_stream_take(&l.stream, len(text), full, now) {
	case .Apply:
	case .Skip:
		return
	case .Ask_Full: // the replica could only grow: a fresh state.full replaces it
		mlink_send(l, window_msg_subscribe())
		return
	}
	checks_before := checks_key(&l.replica)
	if e := replica_apply(&l.replica, text, runtime.heap_allocator(), MIRROR_READ_MAX); e != "" {
		log_fln("Deckhand: machine %s: its state was refused (%s)", l.name, text_clean(e, 200))
		if mirror_stream_refused(&l.stream, full, now) do mlink_send(l, window_msg_subscribe())
		return
	}
	mirror_stream_applied(&l.stream, full)
	if checks_key(&l.replica) != checks_before do machines_publish() // its checklist (Machine_View.checklist)
	mirror_merge(l.no, &l.replica, &l.mirror)
	mirror_alerts(l.no, &l.replica, &l.mirror, l.core_run) // its bell and its jobs that need you, rung here (M6-F)
	l.merged = true
	if autotest_active do fmt.printfln("[autotest] machine %s: state %d", l.name, l.replica.version)
}

// What its checklist is, to see that it changed (temp).
@(private = "file")
checks_key :: proc(r: ^State) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in r.live.checklist do fmt.sbprintf(&b, "%s|%v|%s;", c.id, c.state, c.command)
	return strings.to_string(b)
}

// Its entries leave State, and its replica goes (removed, or Machines over SSH turned off).
@(private = "file")
mlink_unmerge :: proc(l: ^Mach_Link) {
	if !l.merged && l.replica.version == 0 do return
	mirror_drop(l.no, &l.mirror)
	replica_free(&l.replica, runtime.heap_allocator())
	l.merged = false
}

// Other machines' projects into State again (apply_scan replaced the list: sessions.odin).
machines_projects_again :: proc() {
	for l in mach.links do if l.merged do for p in l.mirror.projects do append(&state.projects, p)
}

// One of machine p.machine's projects selected here: its sessions, once that machine has it
// selected too (select_project goes to it; the reply's state brings them).
machine_select_project :: proc(p: Project) {
	state.selected_project = p.id
	l, _ := mlink_find(p.machine)
	if l == nil do return
	mirror_sessions_show(l.no, &l.mirror)
	mlink_send(l, hub_command_json(Select_Project{project_id = id_local(p.id)}, "", .UI))
}

// Frames from an online link. Caps from the first byte: what a window would act on is dropped
// here, unread (§8.3). M6-B reads the state stream; nothing else is taken yet.
@(private = "file")
mlink_pump :: proc(l: ^Mach_Link) {
	if _, why := cw.sock_flush(l.sock); why != .None {
		mlink_down(l, {stderr = "the connection ended"})
		return
	}
	for _ in 0 ..< 256 {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD() // each frame's temp memory goes with it (a state message is up to a frame)
		f, err := cw.sock_recv(l.sock, context.temp_allocator)
		if err == .Closed {
			mlink_reap(l)
			mlink_down(l, {exited = l.exited, exit_code = l.exit_code, stderr = len(l.errbuf) > 0 ? string(l.errbuf[:]) : "the connection ended"})
			return
		}
		if err != .None do return
		if f.channel != cw.JSON_CHANNEL {
			machine_term_frame(l.no, f) // one of its terminals, relayed to the window (machine_route.odin)
			continue
		}
		if f.kind != u8(cw.Kind.Data) do continue
		kind := hub_msg_type(string(f.payload)) // parsed once here; a state message once more, into the replica
		if hub_msg_dropped(kind) {
			mach.dropped += 1
			if autotest_active do fmt.printfln("[autotest] machine %s: dropped %s", l.name, kind)
			continue
		}
		switch kind {
		case STATE_FULL, STATE_DELTA:
			mlink_state(l, string(f.payload), kind == STATE_FULL)
		case "result", "finished": // the user's commands it ran (machine_route.odin)
			machine_route_reply(l.no, string(f.payload))
		case "term.attached", "term.scroll":
			machine_term_json(l.no, kind, string(f.payload))
		case "hub.taken":
			by := json_path(string(f.payload), "by")
			mlink_close(l)
			machine_route_down(l.no)
			page_forwards_drop(l.no)
			l.phase = .Stopped
			l.backoff = {}
			mlink_set(l, .Taken, by != "" && by != "<invalid json>" ? fmt.tprintf("viewed from %s", hub_from_name(by)) : "in use by that machine's own window")
			return
		}
	}
}

// What another machine's core sends that is never acted on here: its window's requests and
// confirmations (M6-A), and a tab host's calls and reports: its agents' browser, app and file-view
// tabs live on that machine only (§8.2), never in this Mac's window or its CEF. (Its core sends
// none: tabhost_route.odin's tab_host_up.)
hub_msg_dropped :: proc(kind: string) -> bool {
	switch kind {
	case "window.request", "confirmation.parked", "tab_host.call", "tab_host.event":
		return true
	}
	return false
}

// A message's type, read without decoding the rest ("" = not one).
hub_msg_type :: proc(text: string) -> string {
	v, err := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if err != nil do return ""
	o, ok := v.(json.Object)
	if !ok do return ""
	t, _ := o["type"].(json.String)
	return t
}

@(private = "file")
mlink_read_raw :: proc(l: ^Mach_Link, cap: int) {
	if l.fd < 0 do return
	buf: [16 << 10]u8
	for len(l.inbuf) < cap {
		n := posix.read(l.fd, &buf[0], len(buf))
		if n > 0 {
			append(&l.inbuf, ..buf[:n])
			continue
		}
		if n == 0 { // EOF: the child closed its end
			posix.close(l.fd)
			l.fd = -1
		}
		return
	}
}

@(private = "file")
mlink_read_err :: proc(l: ^Mach_Link) {
	if l.err_fd < 0 do return
	buf: [4096]u8
	for {
		n := posix.read(l.err_fd, &buf[0], len(buf))
		if n <= 0 {
			if n == 0 {
				posix.close(l.err_fd)
				l.err_fd = -1
			}
			return
		}
		room := MACHINE_STDERR_MAX - len(l.errbuf)
		if room > 0 do append(&l.errbuf, ..buf[:min(int(n), room)])
	}
}

@(private = "file")
mlink_reap :: proc(l: ^Mach_Link) {
	if l.pid <= 0 || l.exited do return
	st: i32
	if posix.waitpid(l.pid, &st, {.NOHANG}) != l.pid do return
	l.exited = true
	if posix.WIFEXITED(st) do l.exit_code = int(posix.WEXITSTATUS(st))
	else do l.exit_code = -1
	mlink_read_err(l)
}

// At the core's end: every link closed, every child reaped.
machines_stop :: proc() {
	page_forwards_stop() // its web pages' ssh children end (machine_page.odin)
	machine_install_stop() // installs' children end, their temp dirs go (machine_install.odin)
	for l in mach.links do mlink_close(l, wait = true)
}

@(private = "file")
mlink_find :: proc(no: u64) -> (^Mach_Link, int) {
	for l, i in mach.links do if l.no == no do return l, i
	return nil, -1
}

@(private = "file")
mlink_free :: proc(l: ^Mach_Link) {
	heap := runtime.heap_allocator()
	for s in ([?]string{l.name, l.target, l.os, l.arch, l.core_path, l.via, l.version, l.error, l.core_run, l.install_why}) do delete(s, heap)
	delete(l.inbuf)
	delete(l.errbuf)
	free(l, heap)
}

// ---- the commands (user-only: command_table.odin) ----

// What the user typed for a machine, as ssh takes it: spaces trimmed, and a leading `ssh ` or an
// `ssh://` (and a trailing /) dropped, as people paste them. Temp (a slice of s).
machine_target_clean :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if len(t) > 4 && strings.equal_fold(t[:4], "ssh ") do t = strings.trim_space(t[4:])
	if len(t) > 6 && strings.equal_fold(t[:6], "ssh://") do t = strings.trim_right(t[6:], "/")
	return t
}

// Why the add field's text cannot be used, in plain words with an example ("" = it can).
machine_target_plain_error :: proc(target: string) -> string {
	if target == "" do return "Type a machine: user@host or a name from ~/.ssh/config, like me@nuc.local"
	if machine_target_error(target) == "" do return machine_target_part_missing(target) ? MACHINE_PART_ERROR : ""
	if machine_target_has_port(target) do return MACHINE_PORT_ERROR
	if len(target) > 255 do return "That is too long for a machine's address"
	if strings.contains_any(target, " \t") || target[0] == '-' do return "Type only the machine, like me@nuc.local: ssh's options go in ~/.ssh/config"
	return fmt.tprintf("%q can't be used: type user@host or a name from ~/.ssh/config (letters, digits and . _ - @), like me@nuc.local", text_clean(target, 40))
}

// What Deckhand calls a machine unless the user names it: its target's host part (nuc for
// me@nuc.home.arpa), an ~/.ssh/config name as it is, an IP address whole. Temp (a slice).
machine_default_name :: proc(target: string) -> string {
	h := target
	if i := strings.last_index_byte(h, '@'); i >= 0 do h = h[i + 1:]
	if i := strings.index_byte(h, ':'); i >= 0 do h = h[:i]
	ip := true
	for c in transmute([]u8)h do if !(c >= '0' && c <= '9') && c != '.' do ip = false
	if !ip do if i := strings.index_byte(h, '.'); i > 0 do h = h[:i]
	return h != "" ? h : target
}

// A machine's name as the user gave it: one line, trimmed, at most 64 bytes (whole runes). Temp.
machine_name_clean :: proc(name: string) -> string {
	return strings.trim_space(cut_utf8(strings.trim_space(one_line(name, context.temp_allocator)), 64))
}

@(private = "file")
machine_name_taken :: proc(name: string, but: u64 = 0) -> bool {
	for l in mach.links do if l.no != but && strings.equal_fold(l.name, name) do return true
	return false
}

machine_add_apply :: proc(c: Machine_Add) -> Result {
	if !state.settings.remote_machines do return fail("turn on Settings › Machines over SSH first")
	if !core_separate do return fail("machines need Run sessions in a background core (the gear)")
	if !mach.loaded do return fail("machines.json could not be read: fix or remove it first")
	target := machine_target_clean(c.target)
	if c.via != "" {
		if !TEST_HOOKS do return fail("via is only for development and test builds")
		target = c.target
	} else {
		if w := machine_target_plain_error(target); w != "" do return fail(w)
		for l in mach.links do if l.target == target do return fail(fmt.tprintf("%s is already in your machines, as %s", target, l.name))
	}
	name := machine_name_clean(c.name)
	if name == "" || name == strings.trim_space(c.target) {
		name = machine_default_name(target) // nuc, not me@nuc.home.arpa
		if machine_name_taken(name) do name = target // two machines called nuc: the second by its whole target
	}
	if w := machine_name_error(name); w != "" do return fail(w)
	if machine_name_taken(name) do return fail(fmt.tprintf("a machine is already called %s", name))
	if mach.next > MACHINE_NO_MAX do return fail("no machine numbers left")
	heap := runtime.heap_allocator()
	l := new(Mach_Link, heap)
	l.m = Machine{no = mach.next, name = strings.clone(name, heap), target = strings.clone(target, heap), via = strings.clone(c.via, heap)}
	l.fd, l.err_fd = -1, -1
	l.auto_install = true // the user's add: no core there, and Deckhand installs one (M6-E)
	mach.next += 1
	append(&mach.links, l)
	if w := machines_save(); w != "" {
		pop(&mach.links)
		mach.next -= 1
		mlink_free(l)
		return fail(w)
	}
	machines_publish()
	return {ok = true, created_id = l.no}
}

// What Remove asks first.
machine_remove_question :: proc(name: string) -> string {
	return fmt.tprintf("Remove %s from Deckhand? Nothing on it is deleted, and its sessions keep running there. Its web pages open here close, and an install running now stops. You can add it again any time.", name)
}

machine_remove_apply :: proc(c: Machine_Remove, caller: Caller) -> (Result, bool) {
	l, i := mlink_find(c.no)
	if l == nil do return fail(fmt.tprintf("no machine %d", c.no)), false
	// the user confirms (the bar), whoever's policy
	if caller.kind != .Internal {
		gr, go_on, ch := confirm_gate(Machine_Remove{no = c.no}, .Settings_Write, caller, c.confirm, machine_remove_question(l.name), force_ask = true)
		if !go_on do return gr, ch
	}
	page_forwards_drop(l.no) // its web pages' ssh children end
	machine_install_drop(l.no, removed = true) // its install ends (and its remote cleanup runs)
	mlink_close(l, wait = true)
	ordered_remove(&mach.links, i)
	if w := machines_save(); w != "" {
		inject_at(&mach.links, i, l)
		return fail(w), true
	}
	mlink_unmerge(l) // its session on screen: this Mac's last one shows instead (mirror_drop)
	machine_route_down(l.no, gone = true)
	mlink_free(l)
	machines_publish()
	return {ok = true}, true
}

machine_rename_apply :: proc(c: Machine_Rename) -> Result {
	l, _ := mlink_find(c.no)
	if l == nil do return fail(fmt.tprintf("no machine %d", c.no))
	name := machine_name_clean(c.name)
	if w := machine_name_error(name); w != "" do return fail(w)
	if machine_name_taken(name, but = l.no) do return fail(fmt.tprintf("a machine is already called %s", name))
	heap := runtime.heap_allocator()
	if name != l.name {
		old := l.name
		l.name = strings.clone(name, heap)
		if w := machines_save(); w != "" {
			delete(l.name, heap)
			l.name = old
			return fail(w)
		}
		delete(old, heap)
	}
	// an edit is the user's: one that waits for them tries again
	if l.phase == .Stopped && machine_status_waits_for_user(l.status) do l.phase, l.next_at, l.backoff = .Idle, {}, {}
	machines_publish()
	return {ok = true}
}

machine_connect_apply :: proc(c: Machine_Connect) -> Result {
	l, _ := mlink_find(c.no)
	if l == nil do return fail(fmt.tprintf("no machine %d", c.no))
	if !state.settings.remote_machines do return fail("turn on Settings › Machines over SSH first")
	if l.phase == .Up || l.phase == .Hello || l.phase == .Probe do return {ok = true}
	mlink_close(l)
	l.phase, l.next_at, l.backoff, l.login_until = .Idle, {}, {}, {}
	return {ok = true}
}

// A session of this Mac's to hold a tab for a machine (Log in…, Open web page…): the one on
// screen, else the last shown (Home holds only its pi tab; another machine's is not this Mac's).
machine_local_session :: proc() -> ^Open_Session {
	s := cur()
	if s != nil && !s.home && s.machine == 0 do return s
	s = nil
	for &o in state.open_sessions do if !o.home && o.machine == 0 && !o.missing && (s == nil || o.shown_at > s.shown_at) do s = &o
	return s
}

// A session of this Mac's for a tab about another machine (Log in…'s, a web page's): the one in
// view, else a new chat (when pi is there). nil: neither. changed: a chat was opened.
machine_host_session :: proc() -> (s: ^Open_Session, changed: bool) {
	if s = machine_local_session(); s != nil do return
	ch := chats_project()
	if ch == nil || !pi_installed() do return nil, false
	rr, _ := open_new_session(ch^, new_uuid(), "")
	if !rr.ok do return nil, false
	return find_session(rr.created_id), true
}

// What Log in… runs: the link's own ssh (the core's PATH) as the ControlMaster, interactive, in
// /bin/sh with the control path and target as arguments (never in the script's text).
machine_login_argv :: proc(m: Machine, run: string) -> (argv: []string, why: string) {
	if m.via != "" do return nil, "this machine is reached through a test build's command: there is nothing to log in to"
	if w := machine_target_error(m.target); w != "" do return nil, w
	ctl := machine_ctl_path(run, m.no)
	if len(ctl) > MACHINE_CTL_MAX do return nil, fmt.tprintf("ssh's control socket %s is longer than %d bytes", ctl, MACHINE_CTL_MAX)
	out := make([]string, 6, context.temp_allocator)
	out[0], out[1], out[2], out[3], out[4], out[5] = "/bin/sh", "-c", `exec ssh -S "$1" -M -o ControlPersist=600 -- "$2"`, "deckhand-login", ctl, m.target
	return out, ""
}

MACHINE_LOGIN_NO_SESSION :: "Open a chat or session on this Mac, then click Log in… again: the login runs in a tab there"

machine_login_apply :: proc(c: Machine_Login, caller: Caller) -> (Result, bool) {
	l, _ := mlink_find(c.no)
	if l == nil do return fail(fmt.tprintf("no machine %d", c.no)), false
	run, rwhy := sock_runtime_dir_why(context.temp_allocator)
	if rwhy != "" do return fail(rwhy), false
	argv, why := machine_login_argv(l.m, run)
	if why != "" do return fail(why), false
	s, changed := machine_host_session()
	if s == nil do return fail(MACHINE_LOGIN_NO_SESSION), changed
	id, err := shell_tab_start(s, s.cwd, argv = argv, title = fmt.tprintf("Log in to %s", l.name))
	if err != "" do return fail(err), changed
	session_show_tab(s, id)
	focus_session(s.id, caller)
	// the link connects once the login's control socket is there (the tick looks once a second)
	if l.phase != .Up && l.phase != .Hello && l.phase != .Probe {
		mlink_close(l)
		l.phase, l.next_at, l.backoff = .Stopped, {}, {}
		l.login_until = time.tick_add(time.tick_now(), MACHINE_LOGIN_WAIT)
	}
	return {ok = true, created_id = id}, true
}
