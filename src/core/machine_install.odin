package core

// Install and one-click update of another machine's core (docs/plans/background-core.md §8.4, §8.5,
// §10.4 M6-E). User-only (who = .User), never from a hub (this core viewed from another machine),
// behind Settings › Machines over SSH.
//
//   machine_install{no}         Install… (no core there) or Update (an older core of Deckhand's own)
//   machine_install{no,cancel}  Cancel
//   machine_linger{no}          Linux: turn on linger there (`deckhand-core-serve linger --enable`)
//
// One job per machine, at most INSTALLS_MAX at once. Nothing here blocks the core's loop: the
// downloads and the copy are children (their own process group, reaped in the tick), the checks a
// worker thread whose answer the tick picks up.
//
//   Fetching    (Linux only) curl: the release's JSON (the tarball's size), its .sig, the tarball
//   Verifying   worker: Mac → the Core.app of core/current passes our designated requirement
//               (holder_verify); Linux → size, sha256 and the .sig (updatesig, as the updater) over
//               (this Mac's version, the name, size, sha256, cdhash none), then every name under
//               the one top dir (no absolute path, no ..), unpacked here and walked: only dirs and
//               regular files, no links of any kind, no hard links, nothing setuid
//   Copying     ssh (Mux: the link's master) running MACHINE_INSTALL_SCRIPT with the archive on
//               its stdin (a Mac's: `tar -c` of the Core.app, piped; Linux: the verified tarball)
//   Cleaning    on failure after the copy started: ssh `rm -rf` of that staging dir
//   Handing_Over the link connects again; a hello from an older core of Deckhand's own gets
//               core_handover{to:"current"} (as ui, on the link), once; the new core's hello (this
//               Mac's version) ends the job. Its holder upgrades itself if it is older (§7.3,
//               holder_upgrade_tick).
//
// What runs there is fixed text: `sh -c '<script>' dh <nonce> <version>`, the nonce 16 hex digits
// of ours and the version X.Y.Z, both checked here and again by the script, which refuses anything
// else before it touches a file. The paths are the known data dirs; nothing the other machine says
// becomes a path or a command. Its output (exit code, the first INSTALL_OUT_MAX bytes) is shown
// cleaned (text_clean).
//
// Every path out kills the children (SIGTERM to the group, SIGKILL after INSTALL_KILL_WAIT while
// the leader is unreaped, then reaped) and removes the local temp dir: Cancel, a link that was up
// going down, the machine removed, the setting off, the core stopping (and leftovers at start).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:crypto"
import "core:encoding/hex"

import cw "../corewire"
import jg "../jsonguard"
import usig "../updatesig"

Machine_Install :: struct {
	no:     u64,
	cancel: bool,
}

Machine_Linger :: struct {
	no: u64,
}

// What a machine's row says of its job (Machine_View.job).
Machine_Job :: enum u8 {
	None,
	Fetching,
	Verifying,
	Copying,
	Cleaning,
	Handing_Over,
	Failed, // job_note says why; the next click starts again
	Done, // installed (job_note: what its install said, a linger note)
}

MACHINE_JOB_NAMES := [Machine_Job]string {
	.None         = "",
	.Fetching     = "downloading",
	.Verifying    = "checking",
	.Copying      = "installing",
	.Cleaning     = "cleaning up",
	.Handing_Over = "starting",
	.Failed       = "failed",
	.Done         = "installed",
}

// What a machine's row offers for its core (Machine_View.update).
Update_Offer :: enum u8 {
	None,
	Button, // Update: an older core of Deckhand's own folder
	Command_Only, // its core runs from elsewhere: what to do is shown, nothing is touched
}

Install_Kind :: enum u8 {
	Copy_App, // another Mac (this arch): Deckhand Core.app of core/current
	Tarball, // Linux x86_64: the release's tarball
}

INSTALLS_MAX :: 2 // at once, every machine's
INSTALLS_BUSY :: "installs are running: wait for one" // a start's refusal while INSTALLS_MAX run (after the count)
INSTALL_FETCH_WAIT :: 31 * time.Minute // curl's own --max-time is 30 min
INSTALL_COPY_WAIT :: 15 * time.Minute
INSTALL_CLEAN_WAIT :: 30 * time.Second
INSTALL_LINGER_WAIT :: 20 * time.Second
INSTALL_HANDOVER_WAIT :: 3 * time.Minute // the old core gives job runs 2 min
INSTALL_KILL_WAIT :: 1 * time.Second
INSTALL_OUT_MAX :: 4096
INSTALL_NOTE_MAX :: 300
TARBALL_MAX :: i64(128) << 20 // no Linux core comes near it
INSTALL_DIR :: "machine-install" // <data>/machine-install/<temp>: local downloads (0700)

// The data dir of a machine's core, by its OS (MACHINE_CORE_PATHS' root).
MACHINE_DATA_DIRS := [?][2]string {
	{"darwin", "$HOME/Library/Application Support/Deckhand"},
	{"linux", "$HOME/.local/share/deckhand"},
}

machine_data_dir_for :: proc(os_name: string) -> string {
	for d in MACHINE_DATA_DIRS do if d[0] == os_name do return d[1]
	return ""
}

// ---- the plan (pure) ----

// How a core gets to a machine of os_name/arch from this one, or why it cannot.
machine_install_plan :: proc(here_os, here_arch, os_name, arch: string) -> (kind: Install_Kind, why: string) {
	if here_os != "darwin" do return {}, "installs run from a Mac"
	if os_name == "" do return {}, "that machine's OS is not known yet: connect to it first"
	if os_name == here_os && arch == here_arch do return .Copy_App, ""
	if os_name == "linux" && arch == "amd64" do return .Tarball, ""
	if os_name == "linux" do return {}, "Deckhand has no Linux core for that machine's processor yet (x86_64 only)"
	return {}, "Deckhand has no core for that machine's processor"
}

// The Update button's rule. here, there: this Mac's core's version and the machine's ("" or not
// X.Y.Z: a development build). installed: its hello said its core runs from Deckhand's own folder
// (false when it did not say: an older core, fail closed).
machine_update_offer :: proc(here, there: string, status: Machine_Status, skew: cw.Skew, installed: bool) -> Update_Offer {
	h, hok := cw.version_parse(here)
	t, tok := cw.version_parse(there)
	#partial switch status {
	case .Needs_Update: // below CORE_MIN or an older generation (a newer one: update this Mac)
		if skew != .Core_Below_Min && skew != .Core_Older_Generation do return .None
		if hok && tok && !cw.version_less(t, h) do return .None // never a downgrade
	case .Online:
		if !hok || !tok || !cw.version_less(t, h) do return .None
	case:
		return .None
	}
	return installed ? .Button : .Command_Only
}

// What to do instead, for a core outside Deckhand's folder (Command_Only).
machine_update_command :: proc(name: string) -> string {
	return fmt.tprintf("Deckhand on %s wasn't installed by Deckhand, so it can't be updated from here: update it on %s (open Deckhand there)", name, name)
}

// The Linux release asset for a version (scripts/pack-linux.sh) and its one top dir.
core_tarball_name :: proc(version: string) -> string {return usig.linux_tar_name(version, context.temp_allocator)}
core_tarball_top :: proc(version: string) -> string {return strings.trim_suffix(core_tarball_name(version), ".tar.gz")}

// 16 lower-case hex digits.
install_nonce_ok :: proc(s: string) -> bool {
	if len(s) != 16 do return false
	for c in transmute([]u8)s do if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) do return false
	return true
}

// A release version for the remote command: X.Y.Z, digits and dots only.
install_version_ok :: proc(v: string) -> bool {
	_, ok := cw.version_parse(v)
	return ok
}

// The scripts that run there. One line (a csh login shell takes no newline in quotes), no single
// quote (they go inside one), no '!' (csh's history). $1: the nonce, $2: the version; refused
// unless they are what this core checked. The EXIT trap removes only <data>/core/.incoming-<nonce>,
// and only once that dir was made by this run.
@(private = "file")
SCRIPT_HEAD :: `set -eu; n=${1:-}; [ -n "$n" ] && [ -z "$(printf %s "$n" | tr -d 0-9a-f)" ] || exit 64; umask 077; `

MACHINE_INSTALL_SCRIPT_MAC :: SCRIPT_HEAD + `C="$HOME/Library/Application Support/Deckhand"; d="$C/core/.incoming-$n"; mkdir -p "$C/core"; mkdir "$d"; c() { rm -rf -- "$d"; }; trap c EXIT; trap "exit 129" HUP INT TERM; tar -x --no-same-owner --no-same-permissions -f - -C "$d"; "$d/Deckhand Core.app/Contents/MacOS/deckhand-core-serve" install --data "$C"`

MACHINE_INSTALL_SCRIPT_LINUX :: SCRIPT_HEAD + `v=${2:-}; [ -n "$v" ] && [ -z "$(printf %s "$v" | tr -d 0-9.)" ] || exit 64; C="$HOME/.local/share/deckhand"; d="$C/core/.incoming-$n"; mkdir -p "$C/core"; mkdir "$d"; c() { rm -rf -- "$d"; }; trap c EXIT; trap "exit 129" HUP INT TERM; tar -xz --no-same-owner --no-same-permissions -f - -C "$d"; "$d/deckhand-core-$v-linux-x86_64/deckhand-core-serve" install --data "$C" --allow-hubs`

@(private = "file")
CLEANUP_SCRIPT_TAIL :: `rm -rf -- "$C/core/.incoming-$n"`

// The remote command of a job's copy (temp), or why not.
machine_install_remote :: proc(os_name: string, kind: Install_Kind, nonce, version: string) -> (remote, why: string) {
	if !install_nonce_ok(nonce) do return "", "a bad nonce"
	switch kind {
	case .Copy_App:
		if os_name != "darwin" do return "", "a Core.app goes only to a Mac"
		return fmt.tprintf("sh -c '%s' dh %s", MACHINE_INSTALL_SCRIPT_MAC, nonce), ""
	case .Tarball:
		if os_name != "linux" do return "", "the Linux tarball goes only to Linux"
		if !install_version_ok(version) do return "", "a development build has no release to install from"
		return fmt.tprintf("sh -c '%s' dh %s %s", MACHINE_INSTALL_SCRIPT_LINUX, nonce, version), ""
	}
	return "", "unknown install"
}

// The cleanup's remote command (temp): the staging dir of that nonce only.
machine_cleanup_remote :: proc(os_name, nonce: string) -> (remote, why: string) {
	data := machine_data_dir_for(os_name)
	if data == "" || !install_nonce_ok(nonce) do return "", "nothing to clean"
	return fmt.tprintf(`sh -c '%sC="%s"; %s' dh %s`, SCRIPT_HEAD, data, CLEANUP_SCRIPT_TAIL, nonce), ""
}

// Linux's linger, turned on by the user's click (no prompt, no sudo: polkit allows it or not).
MACHINE_LINGER_REMOTE :: `"$HOME/.local/share/deckhand/core/current/deckhand-core-serve" linger --enable`

// `linger --enable`'s answer: its last line that is one of on, off, unknown (a remote rc file's
// lines before it are skipped); anything else is Unknown.
machine_linger_answer :: proc(out: string) -> Linger {
	l := Linger.Unknown
	rest := out
	for line in strings.split_lines_iterator(&rest) {
		switch strings.trim_space(line) {
		case "on":      l = .On
		case "off":     l = .Off
		case "unknown": l = .Unknown
		}
	}
	return l
}

// The tarball's size from the release's JSON (GitHub's REST API: assets[].name, size), or why
// not: the tarball and its .sig both there, the size above 0 and at most TARBALL_MAX.
core_tarball_release_size :: proc(body, name: string) -> (size: i64, why: string) {
	if len(body) > UPDATE_JSON_MAX do return 0, "the release answer is too big"
	v, err := jg.parse_string(body, .JSON, parse_integers = true, allocator = context.temp_allocator)
	if err != nil do return 0, "the release answer is not JSON"
	o, _ := v.(json.Object)
	assets, ok := o["assets"].(json.Array)
	if !ok do return 0, "the release has no assets"
	has_sig := false
	size = -1
	for a in assets {
		ao, aok := a.(json.Object)
		if !aok do continue
		n, _ := ao["name"].(json.String)
		s, _ := ao["size"].(json.Integer)
		if n == name do size = i64(s)
		if n == fmt.tprintf("%s.sig", name) && s > 0 && i64(s) <= UPDATE_SMALL_MAX do has_sig = true
	}
	if size < 0 do return 0, fmt.tprintf("the release has no %s", name)
	if size == 0 || size > TARBALL_MAX do return 0, fmt.tprintf("the release's %s is %d bytes (at most %d)", name, size, TARBALL_MAX)
	if !has_sig do return 0, "the release's Linux core has no signature (.sig)"
	return size, ""
}

// `tar -tzf`'s names: each under top/ (or top/ itself), none absolute, none with a ".." part. "" = fine.
tarball_names_check :: proc(listing, top: string) -> string {
	n := 0
	rest := listing
	for line in strings.split_lines_iterator(&rest) {
		if line == "" do continue
		n += 1
		if n > UPDATE_EXTRACT_MAX_ENTRIES do return "the tarball has too many entries"
		if strings.has_prefix(line, "/") do return "the tarball has an absolute path"
		for p in strings.split(line, "/", context.temp_allocator) do if p == ".." do return "the tarball has a path with .."
		if line != top && line != fmt.tprintf("%s/", top) && !strings.has_prefix(line, fmt.tprintf("%s/", top)) do return fmt.tprintf("the tarball holds more than %s/", top)
	}
	if n == 0 do return "the tarball is empty"
	return ""
}

// The unpacked tarball in root: exactly top, a real dir, with top/deckhand-core-serve a regular
// file; below it only dirs and regular files (no links of any kind, no hard links, nothing setuid
// or setgid, nothing writable by group or others). "" = fine.
tarball_tree_check :: proc(root, top: string) -> string {
	entries, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil do return "cannot read the unpacked tarball"
	if len(entries) != 1 || entries[0].name != top do return fmt.tprintf("the tarball does not hold exactly %s/", top)
	count := 0
	if why := walk(upath(root, top), top, 0, &count); why != "" do return why
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(upath(root, top, CORE_SERVE_BIN), context.temp_allocator), &st) != .OK || !posix.S_ISREG(st.st_mode) do return fmt.tprintf("the tarball has no %s", CORE_SERVE_BIN)
	return ""

	walk :: proc(dir, rel: string, depth: int, count: ^int) -> string {
		if depth > UPDATE_EXTRACT_MAX_DEPTH do return "the tarball's folders nest too deep"
		st: posix.stat_t
		if posix.lstat(strings.clone_to_cstring(dir, context.temp_allocator), &st) != .OK || !posix.S_ISDIR(st.st_mode) do return fmt.tprintf("%s in the tarball is not a folder", rel)
		names, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return "cannot read the unpacked tarball"
		for e in names {
			count^ += 1
			if count^ > UPDATE_EXTRACT_MAX_ENTRIES do return "the tarball has too many files"
			p := upath(dir, e.name)
			r := strings.concatenate({rel, "/", e.name}, context.temp_allocator)
			if posix.lstat(strings.clone_to_cstring(p, context.temp_allocator), &st) != .OK do return fmt.tprintf("cannot read %s in the tarball", r)
			if posix.S_ISLNK(st.st_mode) do return fmt.tprintf("%s in the tarball is a link", r) // first: a link's own mode is 0777 on Linux
			if .ISUID in st.st_mode || .ISGID in st.st_mode do return fmt.tprintf("%s in the tarball is setuid or setgid", r)
			if .IWGRP in st.st_mode || .IWOTH in st.st_mode do return fmt.tprintf("%s in the tarball is writable by others", r)
			switch {
			case posix.S_ISDIR(st.st_mode):
				if why := walk(p, r, depth + 1, count); why != "" do return why
			case posix.S_ISREG(st.st_mode):
				if st.st_nlink > 1 do return fmt.tprintf("%s in the tarball is a hard link", r)
			case:
				return fmt.tprintf("%s in the tarball is not a file or folder", r)
			}
		}
		return ""
	}
}

// A Linux tarball's .sig (M6-L4, scripts/release-linux.sh): updatesig's, v3 with `cdhash none`
// only (allow_none, which the app's own updater never passes).
tarball_sig_parse :: proc(text: string) -> (cdhash, sig_b64: string, format: usig.Format, ok: bool) {
	cdhash, sig_b64, format, ok = usig.sig_file_parse(text, allow_none = true)
	if !ok || format != .V3 || cdhash != usig.CDHASH_NONE do return "", "", .V3, false
	return
}

// The downloaded tarball (path) against its .sig (sig_text) for version, under key; then its
// names (listing) and the tree unpacked in root (tarball_tree_check, by the caller). want_size:
// the release's. "" = fine.
tarball_verify :: proc(path, sig_text, version: string, want_size: i64, key: string) -> string {
	name := core_tarball_name(version)
	sum, size, ok := usig.file_sha256(path)
	if !ok do return "cannot read the download"
	if size != want_size do return fmt.tprintf("the download is %d bytes, the release says %d", size, want_size)
	if size > TARBALL_MAX do return "the download is too big"
	cd, sig_b64, format, sok := tarball_sig_parse(sig_text)
	if !sok do return "its signature file is not one Deckhand reads"
	manifest := usig.manifest(version, name, size, sum, cd, context.temp_allocator, format)
	if !usig.verify(key, transmute([]byte)manifest, sig_b64) do return "the download's signature does not match, so nothing was installed: try again later, or update Deckhand on this Mac first"
	log_fln("Deckhand: install: %s verified, sha256 %s", name, sum) // what was installed, for the record (#135)
	return ""
}

// ---- the jobs (main thread) ----

// A child of a job: its own process group, its stdout and stderr on one pipe.
@(private = "file")
Inst_Child :: struct {
	pid:      posix.pid_t, // the group leader (0: none, or reaped)
	fd:       posix.FD, // -1: none
	out:      [INSTALL_OUT_MAX]u8,
	out_n:    int,
	started:  time.Tick,
	wait:     time.Duration,
	term_at:  time.Tick, // SIGTERM sent
	killed:   bool,
	exit:     int, // once reaped (-1: by a signal)
	timed_out: bool,
}

// A worker's check (heap). The worker owns it until done; a job that ends first marks it
// abandoned, and the worker then removes its dir and frees it.
@(private = "file")
Inst_Verify :: struct {
	mu:        sync.Mutex,
	done:      bool,
	abandoned: bool,
	kind:      Install_Kind,
	path:      string, // the Core.app, or the tarball
	sig:       string, // the tarball's .sig file
	version:   string,
	size:      i64,
	key:       string,
	work:      string, // the job's temp dir (the worker unpacks into it; removes it when abandoned)
	why:       string, // the answer ("" = it passed)
	found:     string, // Copy_App: the Core.app's release version, as its core will say it ("" = a development build)
}

@(private = "file")
Inst_Job :: struct {
	no:        u64,
	name:      string, // heap (all strings here)
	target:    string,
	via:       bool,
	os_name:   string,
	kind:      Install_Kind,
	update:    bool, // a core runs there: handed over after the copy
	phase:     Machine_Job,
	nonce:     string,
	version:   string, // this Mac's core's (Tarball: the release fetched)
	before:    string, // an update: the run id of the core that answered there before it (its hello's `core`)
	work:      string, // the local temp dir ("" = none)
	app:       string, // the Core.app copied (Copy_App)
	size:      i64, // the tarball's, from the release
	step:      int, // Fetching: 0 the JSON, 1 the .sig, 2 the tarball
	child:     Inst_Child,
	verify:    ^Inst_Verify,
	copied:    bool, // the copy started: the remote staging dir may be there
	note:      string, // what the row says (cleaned)
	sent:      bool, // core_handover went
	until:     time.Tick, // Handing_Over: the deadline
	was_up:    bool, // the link was up when it started (its drop cancels)
	gone:      bool, // the machine was removed: the job goes once its cleanup is done
}

@(private = "file")
Linger_Job :: struct {
	no:    u64,
	name:  string, // heap
	child: Inst_Child,
	gone:  bool, // its machine was removed, or Machines over SSH went off: no answer is shown
}

@(private = "file")
inst: struct {
	jobs:    [dynamic]^Inst_Job,
	lingers: [dynamic]^Linger_Job,
}

when TEST_HOOKS {
	install_ssh_for_test: []string // in place of `ssh … <target>` (unit tests): the remote command follows
	install_curl_for_test: []string // in place of curl's argv (unit tests): the URL and output path follow
	install_key_for_test: string // the release key (unit tests)
	install_here_for_test: [2]string // this Mac's OS and arch (unit tests)
	install_app_for_test: string // the Core.app to copy (unit tests: an unsigned fake)
	install_skip_dr_for_test: bool // its designated requirement is not checked (the fake has no signature)
}

@(private = "file")
job_find :: proc(no: u64) -> (^Inst_Job, int) {
	for j, i in inst.jobs do if j.no == no do return j, i
	return nil, -1
}

// What machine no's row says of its job (machines.odin's machines_publish). Temp.
machine_install_view :: proc(no: u64) -> (job: Machine_Job, note: string) {
	j, _ := job_find(no)
	if j == nil do return .None, ""
	return j.phase, j.note
}

@(private = "file")
job_active :: proc(j: ^Inst_Job) -> bool {return j.phase != .Failed && j.phase != .Done && j.phase != .None}

@(private = "file")
job_note :: proc(j: ^Inst_Job, s: string) {
	heap := runtime.heap_allocator()
	delete(j.note, heap)
	j.note = strings.clone(text_clean(s, INSTALL_NOTE_MAX), heap)
}

@(private = "file")
job_set :: proc(j: ^Inst_Job, p: Machine_Job, note := "") {
	j.phase = p
	if note != "" || p == .Failed do job_note(j, note)
	if autotest_active do fmt.printfln("[autotest] machine %s install: %s%s%s", j.name, MACHINE_JOB_NAMES[p], j.note != "" ? ": " : "", j.note)
	machines_changed()
}

@(private = "file")
job_free :: proc(j: ^Inst_Job) {
	heap := runtime.heap_allocator()
	for s in ([?]string{j.name, j.target, j.os_name, j.nonce, j.version, j.before, j.work, j.app, j.note}) do delete(s, heap)
	free(j, heap)
}

// This Mac's OS and arch as machine_uname_parse names them.
@(private = "file")
here_os_arch :: proc() -> (string, string) {
	when TEST_HOOKS do if install_here_for_test[0] != "" do return install_here_for_test[0], install_here_for_test[1]
	arch := ODIN_ARCH == .arm64 ? "arm64" : "amd64"
	os_name := ""
	when ODIN_OS == .Darwin do os_name = "darwin"
	when ODIN_OS == .Linux do os_name = "linux"
	return os_name, arch
}

// The key the tarball's .sig verifies under.
@(private = "file")
install_key :: proc() -> string {
	when TEST_HOOKS do if install_key_for_test != "" do return install_key_for_test
	when DECKHAND_UPDATE_TEST {
		if autotest_active && hook_env(.Core_Release) != "" do return UPDATE_TEST_PUBLIC_KEY
	}
	return UPDATE_PUBLIC_KEY
}

// The ssh of a job's step (temp): the shared builder's Mux mode on the link's control socket, or a
// test build's stand-in.
@(private = "file")
install_ssh :: proc(no: u64, target: string, via: bool, remote: string) -> (argv: []string, why: string) {
	when TEST_HOOKS {
		if install_ssh_for_test != nil || via {
			out := make([dynamic]string, context.temp_allocator)
			if install_ssh_for_test != nil {
				for a in install_ssh_for_test do append(&out, a)
			} else {
				for f in strings.fields(hook_env(.Test_Ssh), context.temp_allocator) do append(&out, f)
				if len(out) == 0 do return nil, "a via machine installs only with DECKHAND_TEST_SSH (a test build's stand-in for ssh)"
			}
			append(&out, remote)
			return out[:], ""
		}
	}
	if via do return nil, "via is only for development and test builds"
	run, rwhy := sock_runtime_dir_why(context.temp_allocator)
	if rwhy != "" do return nil, rwhy
	return ssh_argv(target, .Mux, machine_ctl_path(run, no), remote = remote)
}

// The Core.app to copy to another Mac: core/current's, else (a development build, which installs
// none) the one this core runs from. "" = none.
@(private = "file")
install_app_source :: proc() -> string {
	when TEST_HOOKS do if install_app_for_test != "" do return install_app_for_test
	if s := core_serve_of(home_root, CORE_CURRENT); s != "" {
		if r := real_dir_of(s); r != "" do return app_of_serve(r)
	}
	if exe := executable_path(); exe != "" do return app_of_serve(exe)
	return ""

	app_of_serve :: proc(serve: string) -> string {
		suffix := fmt.tprintf("/%s/Contents/MacOS/%s", CORE_APP, CORE_SERVE_BIN)
		if !strings.has_suffix(serve, suffix) do return ""
		return serve[:len(serve) - len(suffix) + 1 + len(CORE_APP)]
	}
	real_dir_of :: proc(p: string) -> string {
		r := posix.realpath(strings.clone_to_cstring(p, context.temp_allocator), nil)
		if r == nil do return ""
		defer posix.free(r)
		return strings.clone(string(r), context.temp_allocator)
	}
}

// A private temp dir for a job (heap), under <data>/machine-install.
@(private = "file")
install_work_dir :: proc() -> string {
	if home_root == "" do return ""
	base := upath(home_root, INSTALL_DIR)
	if !private_dir(base) do return ""
	tmpl := strings.clone_to_cstring(upath(base, "job-XXXXXX"), context.temp_allocator)
	d := posix.mkdtemp(transmute([^]byte)tmpl)
	if d == nil do return ""
	return strings.clone(string(d), runtime.heap_allocator())
}

// At serve's start: what an earlier run left (it died mid-job).
machine_install_leftovers :: proc() {
	if home_root != "" do remove_tree(upath(home_root, INSTALL_DIR))
}

@(private = "file")
random_nonce :: proc() -> string {
	b: [8]u8
	crypto.rand_bytes(b[:])
	return strings.clone(string(hex.encode(b[:], context.temp_allocator)), runtime.heap_allocator())
}

// ---- the commands ----

machine_install_apply :: proc(c: Machine_Install, caller: Caller) -> Result {
	if !state.settings.remote_machines do return fail("turn on Settings › Machines over SSH first")
	if c.cancel {
		j, _ := job_find(c.no)
		if j != nil && job_active(j) do job_fail(j, "cancelled")
		machine_install_why_clear(c.no) // why an install could not start: stale now (machines.odin)
		return {ok = true}
	}
	return machine_install_start(c.no)
}

// Starts machine no's install or update (Install…, Update, or machine_add's first finding).
machine_install_start :: proc(no: u64) -> Result {
	f, ok := machine_facts(no)
	if !ok do return fail(fmt.tprintf("no machine %d", no))
	if !core_separate do return fail("machines need Run sessions in a background core (the gear)")
	if j, _ := job_find(no); j != nil && job_active(j) do return fail(fmt.tprintf("%s is already being %s", f.name, MACHINE_JOB_NAMES[j.phase]))
	n := 0
	for j in inst.jobs do if job_active(j) do n += 1
	if n >= INSTALLS_MAX do return fail(fmt.tprintf("%d %s", INSTALLS_MAX, INSTALLS_BUSY))
	update := false
	if f.status != .Not_Installed {
		switch machine_update_offer(core_version(), f.version, f.status, f.skew, f.installed) {
		case .Button:       update = true
		case .Command_Only: return fail(machine_update_command(f.name))
		case .None:         return fail(fmt.tprintf("%s has nothing to install or update", f.name))
		}
	}
	here_os, here_arch := here_os_arch()
	os_name, arch := f.os, f.arch
	if f.via do os_name, arch = here_os, here_arch // a test build's "machine" is this Mac
	kind, why := machine_install_plan(here_os, here_arch, os_name, arch)
	if why != "" do return fail(why)
	version := core_version()
	if kind == .Tarball && !install_version_ok(version) do return fail("this is a development build: it has no release to install on Linux from")
	// the old job's, if any (failed or done): replaced
	if old, i := job_find(no); old != nil {
		ordered_remove(&inst.jobs, i)
		job_free(old)
	}
	heap := runtime.heap_allocator()
	j := new(Inst_Job, heap)
	j^ = {no = no, name = strings.clone(f.name, heap), target = strings.clone(f.target, heap), via = f.via, os_name = strings.clone(os_name, heap), kind = kind, update = update, version = strings.clone(version, heap), before = strings.clone(update ? f.core_run : "", heap), nonce = random_nonce(), was_up = f.status == .Online}
	j.child.fd = -1
	if inst.jobs == nil do inst.jobs = make([dynamic]^Inst_Job, heap)
	append(&inst.jobs, j)
	j.work = install_work_dir()
	if j.work == "" {
		job_set(j, .Failed, "cannot make a private folder for the install")
		return fail(j.note)
	}
	switch kind {
	case .Copy_App:
		app := install_app_source()
		if app == "" {
			work_remove(j)
			job_set(j, .Failed, "this Mac has no Deckhand Core.app to copy")
			return fail(j.note)
		}
		j.app = strings.clone(app, heap)
		verify_start(j)
	case .Tarball:
		job_set(j, .Fetching)
		fetch_step(j)
	}
	machine_install_why_clear(no) // it started: why it could not before is stale (machines.odin)
	return {ok = true}
}

machine_linger_apply :: proc(c: Machine_Linger, caller: Caller) -> Result {
	if !state.settings.remote_machines do return fail("turn on Settings › Machines over SSH first")
	f, ok := machine_facts(c.no)
	if !ok do return fail(fmt.tprintf("no machine %d", c.no))
	if f.os != "linux" && !f.via do return fail("linger is Linux's")
	for l in inst.lingers do if l.no == c.no do return {ok = true}
	argv, why := install_ssh(c.no, f.target, f.via, MACHINE_LINGER_REMOTE)
	if why != "" do return fail(why)
	heap := runtime.heap_allocator()
	l := new(Linger_Job, heap)
	l^ = {no = c.no, name = strings.clone(f.name, heap)}
	l.child.fd = -1
	if !child_start(&l.child, argv, -1, INSTALL_LINGER_WAIT) {
		delete(l.name, heap)
		free(l, heap)
		return fail("ssh could not start")
	}
	if inst.lingers == nil do inst.lingers = make([dynamic]^Linger_Job, heap)
	append(&inst.lingers, l)
	return {ok = true}
}

// ---- the steps ----

// The job fails (why): its child gets SIGTERM (SIGKILL after INSTALL_KILL_WAIT, then reaped:
// child_tick), its worker is let go, the local temp dir removed; once the child is gone, a copy
// that had started is followed by the cleanup's ssh (Cleaning), then Failed.
@(private = "file")
job_fail :: proc(j: ^Inst_Job, why: string) {
	child_signal(&j.child, .SIGTERM)
	verify_abandon(j)
	work_remove(j)
	job_note(j, why)
	j.phase = .Cleaning
	if autotest_active do fmt.printfln("[autotest] machine %s install: stopping: %s", j.name, j.note)
	machines_changed()
	cleaning_tick(j, time.tick_now())
}

// Cleaning's turn: the job's child gone, then the remote cleanup (once, if the copy had started),
// then Failed.
@(private = "file")
cleaning_tick :: proc(j: ^Inst_Job, now: time.Tick) {
	if !child_tick(&j.child, now) do return
	if j.copied {
		j.copied = false
		if remote, rwhy := machine_cleanup_remote(j.os_name, j.nonce); rwhy == "" {
			if argv, awhy := install_ssh(j.no, j.target, j.via, remote); awhy == "" && child_start(&j.child, argv, -1, INSTALL_CLEAN_WAIT) do return
		}
	}
	j.phase = .Failed
	if autotest_active do fmt.printfln("[autotest] machine %s install: failed: %s", j.name, j.note)
	machines_changed()
}

@(private = "file")
work_remove :: proc(j: ^Inst_Job) {
	if j.work == "" do return
	if j.verify == nil do remove_tree(j.work) // else the worker's (verify_abandon)
	delete(j.work, runtime.heap_allocator())
	j.work = ""
}

// The Linux tarball's downloads, one child at a time: the release's JSON, the .sig, the tarball.
@(private = "file")
fetch_step :: proc(j: ^Inst_Job) {
	base, api := fmt.tprintf("%sv%s/", UPDATE_DOWNLOAD_URL, j.version), fmt.tprintf("https://api.github.com/repos/%s/releases/tags/v%s", UPDATE_REPO, j.version)
	test := false
	when TEST_HOOKS {
		if d := hook_env(.Core_Release); d != "" && autotest_active {
			base, api, test = d, fmt.tprintf("%srelease.json", d), true
		}
		if install_curl_for_test != nil do test = true
	}
	name := core_tarball_name(j.version)
	url, out: string
	max: i64
	switch j.step {
	case 0: url, out, max = api, upath(j.work, "release.json"), UPDATE_JSON_MAX
	case 1: url, out, max = fmt.tprintf("%s%s.sig", base, name), upath(j.work, "tarball.sig"), UPDATE_SMALL_MAX
	case 2: url, out, max = fmt.tprintf("%s%s", base, name), upath(j.work, name), j.size
	}
	argv := curl_argv(url, "deckhand", test, max, out, json_api = j.step == 0)
	when TEST_HOOKS do if install_curl_for_test != nil {
		a := make([dynamic]string, context.temp_allocator)
		for x in install_curl_for_test do append(&a, x)
		append(&a, url, out)
		argv = a[:]
	}
	if !child_start(&j.child, argv, -1, INSTALL_FETCH_WAIT) do job_fail(j, "cannot run curl")
}

@(private = "file")
fetch_done :: proc(j: ^Inst_Job) {
	if j.child.exit != 0 {
		job_fail(j, j.child.timed_out ? "the download timed out" : "the download failed (offline, or GitHub did not answer)")
		return
	}
	switch j.step {
	case 0:
		b, err := os.read_entire_file(upath(j.work, "release.json"), context.temp_allocator)
		if err != nil {
			job_fail(j, "cannot read the release")
			return
		}
		size, why := core_tarball_release_size(string(b), core_tarball_name(j.version))
		if why != "" {
			job_fail(j, why)
			return
		}
		j.size = size
	case 2:
		verify_start(j)
		return
	}
	j.step += 1
	fetch_step(j)
}

@(private = "file")
verify_start :: proc(j: ^Inst_Job) {
	heap := runtime.heap_allocator()
	v := new(Inst_Verify, heap)
	v^ = {kind = j.kind, version = strings.clone(j.version, heap), size = j.size, key = strings.clone(install_key(), heap), work = strings.clone(j.work, heap)}
	if j.kind == .Copy_App {
		v.path = strings.clone(j.app, heap)
	} else {
		v.path = strings.clone(upath(j.work, core_tarball_name(j.version)), heap)
		v.sig = strings.clone(upath(j.work, "tarball.sig"), heap)
	}
	j.verify = v
	job_set(j, .Verifying)
	thread.run_with_poly_data(v, proc(v: ^Inst_Verify) {
		why := verify_run(v)
		sync.lock(&v.mu)
		v.why = strings.clone(why, runtime.heap_allocator())
		v.done = true
		abandoned := v.abandoned
		sync.unlock(&v.mu)
		if abandoned {
			remove_tree(v.work)
			verify_free(v)
		}
		free_all(context.temp_allocator)
	})
}

// The worker's check (any thread). "" = it passed.
@(private = "file")
verify_run :: proc(v: ^Inst_Verify) -> string {
	switch v.kind {
	case .Copy_App:
		st: posix.stat_t
		serve := fmt.tprintf("%s/Contents/MacOS/%s", v.path, CORE_SERVE_BIN)
		if posix.lstat(strings.clone_to_cstring(serve, context.temp_allocator), &st) != .OK || !posix.S_ISREG(st.st_mode) do return fmt.tprintf("%s has no %s", v.path, CORE_SERVE_BIN)
		v.found = strings.clone(app_release_version(v.path), runtime.heap_allocator())
		when TEST_HOOKS do if install_skip_dr_for_test do return ""
		return holder_verify(v.path) // its designated requirement, as our own signature gives it
	case .Tarball:
		sig, err := os.read_entire_file(v.sig, context.temp_allocator)
		if err != nil do return "cannot read the signature"
		if why := tarball_verify(v.path, string(sig), v.version, v.size, v.key); why != "" do return why
		top := core_tarball_top(v.version)
		listing, lst := run_group({"/usr/bin/tar", "-tzf", v.path}, 60 * time.Second, cap = 16 << 20)
		if lst != .Ok do return "cannot list the tarball"
		if why := tarball_names_check(listing, top); why != "" do return why
		x := upath(v.work, "x")
		if !private_dir(x) do return "cannot make a folder to unpack into"
		defer remove_tree(x)
		if _, st := run_group({"/usr/bin/tar", "-xzf", v.path, "-C", x}, 120 * time.Second, cap = 1 << 20); st != .Ok do return "cannot unpack the tarball"
		return tarball_tree_check(x, top)
	}
	return "unknown install"
}

// A Core.app's release version as its core says it (core_version: a pre-release or none is a
// development build's ""). Temp; any thread.
app_release_version :: proc(app: string) -> string {
	v := plist_value(upath(app, "Contents", "Info.plist"), "CFBundleShortVersionString")
	if pv, ok := semver_parse(v); !ok || pv.pre do return ""
	return v
}

// Copy_App, checked: an update never installs a Core.app (found: its version) that is not newer
// than what runs there (core/current's may differ from the running core's). "" = go on.
@(private = "file")
copied_version_check :: proc(j: ^Inst_Job, found: string) -> string {
	if !j.update do return ""
	f, ok := machine_facts(j.no)
	if !ok do return "the machine is gone"
	c, cok := cw.version_parse(found)
	t, tok := cw.version_parse(f.version)
	if cok && tok && !cw.version_less(t, c) do return fmt.tprintf("this Mac's Core.app is %s and %s runs %s: never a downgrade", found, f.name, f.version)
	return ""
}

@(private = "file")
verify_free :: proc(v: ^Inst_Verify) {
	heap := runtime.heap_allocator()
	for s in ([?]string{v.path, v.sig, v.version, v.key, v.work, v.why, v.found}) do delete(s, heap)
	free(v, heap)
}

// The job no longer waits for its worker: freed now if it is done, else by the worker (with the
// job's temp dir).
@(private = "file")
verify_abandon :: proc(j: ^Inst_Job) {
	v := j.verify
	if v == nil do return
	j.verify = nil
	sync.lock(&v.mu)
	done := v.done
	if !done {
		v.abandoned = true
		delete(j.work, runtime.heap_allocator()) // the worker removes it
		j.work = ""
	}
	sync.unlock(&v.mu)
	if done do verify_free(v)
}

// The copy: ssh with the archive on its stdin.
@(private = "file")
copy_start :: proc(j: ^Inst_Job) {
	remote, why := machine_install_remote(j.os_name, j.kind, j.nonce, j.version)
	if why != "" {
		job_fail(j, why)
		return
	}
	ssh, swhy := install_ssh(j.no, j.target, j.via, remote)
	if swhy != "" {
		job_fail(j, swhy)
		return
	}
	in_fd := posix.FD(-1)
	argv := ssh
	switch j.kind {
	case .Copy_App:
		// tar of the checked Core.app, piped to ssh: both in the shell's group (one kill ends both)
		a := make([dynamic]string, context.temp_allocator)
		append(&a, "/bin/sh", "-c", `d=$1; shift; /usr/bin/tar -c --no-mac-metadata -f - -C "$d" "Deckhand Core.app" | "$@"`, "deckhand-copy", filepath.dir(j.app))
		for x in ssh do append(&a, x)
		argv = a[:]
	case .Tarball:
		in_fd = posix.open(strings.clone_to_cstring(upath(j.work, core_tarball_name(j.version)), context.temp_allocator), {.NOFOLLOW, .CLOEXEC})
		if in_fd < 0 {
			job_fail(j, "cannot read the checked tarball")
			return
		}
	}
	ok := child_start(&j.child, argv, in_fd, INSTALL_COPY_WAIT)
	if in_fd >= 0 do posix.close(in_fd)
	if !ok {
		job_fail(j, "ssh could not start")
		return
	}
	j.copied = true
	job_set(j, .Copying)
}

@(private = "file")
copy_done :: proc(j: ^Inst_Job) {
	out := strings.trim_space(string(j.child.out[:j.child.out_n]))
	if j.child.exit != 0 {
		why := j.child.timed_out ? fmt.tprintf("the copy took over %v", INSTALL_COPY_WAIT) : j.child.exit == 64 ? "the other machine refused the install's arguments" : out != "" ? machine_last_line(out) : fmt.tprintf("the install there ended with %d", j.child.exit)
		job_fail(j, why)
		return
	}
	j.copied = false // its own trap removed the staging dir
	work_remove(j)
	// what install said besides the installed path (a linger note, no unit…)
	note := ""
	rest := out
	for line in strings.split_lines_iterator(&rest) do if strings.contains(line, "deckhand-core-serve install:") do note = line
	if note != "" do job_note(j, note)
	j.until = time.tick_add(time.tick_now(), INSTALL_HANDOVER_WAIT)
	job_set(j, .Handing_Over)
	if j.update && machine_link_up(j.no) {
		// what answers on the link now: another core may have connected since the job started
		if f, ok := machine_facts(j.no); !ok || !f.installed {
			job_set(j, .Failed, machine_update_command(j.name))
			return
		}
		j.sent = machine_handover_send(j.no)
	} else {
		machine_reconnect_now(j.no) // its next hello says what runs there
	}
}

// Machine no's hello came (machines.odin) from the core of run id run; installed: its hello said
// it runs from Deckhand's folder. Another run than the one before the copy is the new core (a
// fresh install's first). True: send core_handover{current} on it now (the old core, once).
machine_install_hello :: proc(no: u64, run: string, installed: bool) -> bool {
	j, _ := job_find(no)
	if j == nil || j.phase != .Handing_Over do return false
	if !installed {
		job_set(j, .Failed, machine_update_command(j.name))
		return false
	}
	if run != "" && run != j.before {
		job_set(j, .Done)
		return false
	}
	if j.sent do return false // the old core still waits for its job runs: until j.until
	j.sent = true
	return true // the link sends it (machine_handover_send's text), on the hello's link
}

// core_handover{current} as the user's: what an install's update sends the old core, one text for
// every path (copy_done's up link, a hello's: machines.odin). Temp.
machine_handover_text :: proc(name: string) -> string {
	if autotest_active do fmt.printfln("[autotest] machine %s install: core_handover sent", name)
	return hub_command_json(Core_Handover{to = CORE_CURRENT}, "", .UI)
}

// Machine no's core refused the hub hello (why: its answer): a job waiting for its new core says
// so at once (another Mac's Allow other machines to connect is off until the user turns it on).
machine_install_refused :: proc(no: u64, why: string) {
	j, _ := job_find(no)
	if j == nil || j.phase != .Handing_Over do return
	job_set(j, .Failed, fmt.tprintf("installed, but its core refused this Mac: %s", why))
}

// Machine no's link went down (machines.odin): a job that started on an up link is cancelled
// before its handover; one handing over waits on (the old core quits).
machine_install_link_down :: proc(no: u64) {
	j, _ := job_find(no)
	if j == nil || !j.was_up do return
	#partial switch j.phase {
	case .Fetching, .Verifying, .Copying: job_fail(j, "its link went down")
	}
}

// Machine no is removed, or (no = 0) Machines over SSH went off: every job of it ends.
machine_install_drop :: proc(no: u64, removed := false) {
	for j in inst.jobs do if no == 0 || j.no == no {
		if removed do j.gone = true
		if job_active(j) && j.phase != .Cleaning do job_fail(j, removed ? "the machine was removed" : "Machines over SSH is off")
	}
	for l in inst.lingers do if no == 0 || l.no == no {
		l.gone = true
		child_signal(&l.child, .SIGTERM)
	}
	if removed do for i := len(inst.jobs) - 1; i >= 0; i -= 1 {
		j := inst.jobs[i]
		if j.no == no && !job_active(j) {
			child_reap_now(&j.child)
			ordered_remove(&inst.jobs, i)
			job_free(j)
		}
	}
}

// A job of machine no's is still there (a removed machine's: its remote cleanup).
machine_install_busy :: proc(no: u64) -> bool {
	for j in inst.jobs do if j.no == no do return true
	return false
}

// The core's loop: children read and reaped, workers' answers taken, deadlines.
machine_install_tick :: proc(now: time.Tick) {
	for i := len(inst.jobs) - 1; i >= 0; i -= 1 {
		j := inst.jobs[i]
		#partial switch j.phase {
		case .Fetching:
			if child_tick(&j.child, now) do fetch_done(j)
		case .Verifying:
			v := j.verify
			if v == nil do break
			sync.lock(&v.mu)
			done, why, found := v.done, strings.clone(v.why, context.temp_allocator), strings.clone(v.found, context.temp_allocator)
			sync.unlock(&v.mu)
			if !done do break
			j.verify = nil
			verify_free(v)
			if why == "" && j.kind == .Copy_App do why = copied_version_check(j, found)
			if why != "" do job_fail(j, why)
			else do copy_start(j)
		case .Copying:
			if child_tick(&j.child, now) do copy_done(j)
		case .Cleaning:
			cleaning_tick(j, now)
		case .Handing_Over:
			if time.tick_diff(j.until, now) > 0 do job_set(j, .Failed, j.sent ? "the update did not take: its old core still answers" : "its new core did not come up")
		case .Failed, .Done:
			child_tick(&j.child, now) // a killed child's reap
			if j.gone && j.child.pid <= 0 {
				ordered_remove(&inst.jobs, i)
				job_free(j)
			}
		}
	}
	for i := len(inst.lingers) - 1; i >= 0; i -= 1 {
		l := inst.lingers[i]
		if !child_tick(&l.child, now) do continue
		got := machine_linger_answer(string(l.child.out[:l.child.out_n]))
		if !l.gone { // else its machine went (or Machines over SSH did): nothing to say of it
			if got == .On do machine_linger_set(l.no, .On)
			else do window_toast(fmt.tprintf("Keep running: %s's login manager wants a password, so its jobs still stop when you log out. Run `%s` on %s yourself", l.name, LINGER_COMMAND, l.name), err = true)
		}
		heap := runtime.heap_allocator()
		delete(l.name, heap)
		free(l, heap)
		ordered_remove(&inst.lingers, i)
	}
	// one ended: a machine told that too many installs were running may install now
	n := 0
	for j in inst.jobs do if job_active(j) do n += 1
	if n < INSTALLS_MAX do machine_install_why_clear(0)
}

// The core stops: every child ends now (≤ INSTALL_KILL_WAIT each, then SIGKILL), the local temp
// dirs go (a running worker's when it is done, else the next start's leftovers sweep). The
// other machine's script removes its staging dir when its ssh goes (its EXIT trap).
machine_install_stop :: proc() {
	for j in inst.jobs {
		child_signal(&j.child, .SIGTERM)
		verify_abandon(j)
		work_remove(j)
	}
	for l in inst.lingers do child_signal(&l.child, .SIGTERM)
	deadline := time.tick_add(time.tick_now(), INSTALL_KILL_WAIT + 200 * time.Millisecond)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		left := false
		for j in inst.jobs do if j.child.pid > 0 && !child_tick(&j.child, time.tick_now()) do left = true
		for l in inst.lingers do if l.child.pid > 0 && !child_tick(&l.child, time.tick_now()) do left = true
		if !left do break
		time.sleep(20 * time.Millisecond)
	}
	for j in inst.jobs do child_reap_now(&j.child)
	for l in inst.lingers do child_reap_now(&l.child)
}

// ---- children ----

CHILD_READ_BUDGET :: 64 << 10 // bytes read from one child's output per turn of the loop

// Reads what fd has (non-blocking), at most budget bytes this turn: the first len(keep) bytes ever
// are kept (kept counts them), the rest read and dropped. eof: the writer closed it. A child that
// writes without end costs the loop at most budget per turn (machine_page.odin's children too).
pipe_drain :: proc(fd: posix.FD, keep: []u8, kept: ^int, budget: int) -> (read: int, eof: bool) {
	buf: [4096]u8
	for read < budget {
		n := posix.read(fd, &buf[0], uint(min(len(buf), budget - read)))
		if n == 0 do return read, true
		if n < 0 do return read, false
		read += int(n)
		if kept^ < len(keep) do kept^ += copy(keep[kept^:], buf[:n])
	}
	return read, false
}

// Starts argv in its own process group: stdin in_fd (-1: /dev/null), stdout and stderr one pipe.
@(private = "file")
child_start :: proc(c: ^Inst_Child, argv: []string, in_fd: posix.FD, wait: time.Duration) -> bool {
	child_reap_now(c)
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	p: [2]posix.FD
	if posix.pipe(&p) != .OK do return false
	null_fd := posix.open("/dev/null", {.RDWR, .CLOEXEC})
	defer if null_fd >= 0 do posix.close(null_fd)
	if null_fd < 0 {
		posix.close(p[0]); posix.close(p[1])
		return false
	}
	for x in p do posix.fcntl(x, .SETFD, i32(posix.FD_CLOEXEC))
	attr, fa: [512]u8
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	posix_spawnattr_setflags(&attr, i16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
	posix_spawnattr_setpgroup(&attr, 0)
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	posix_spawn_file_actions_adddup2(&fa, i32(in_fd >= 0 ? in_fd : null_fd), 0)
	posix_spawn_file_actions_adddup2(&fa, i32(p[1]), 1)
	posix_spawn_file_actions_adddup2(&fa, i32(p[1]), 2)
	pid: posix.pid_t
	sync.rw_mutex_shared_lock(&fork_lock)
	err := posix.posix_spawnp(&pid, cargv[0], &fa, &attr, raw_data(cargv), posix.environ)
	sync.rw_mutex_shared_unlock(&fork_lock)
	posix.close(p[1])
	if err != .NONE {
		posix.close(p[0])
		return false
	}
	posix.fcntl(p[0], .SETFL, posix.fcntl(p[0], .GETFL) | posix.O_NONBLOCK)
	c^ = {pid = pid, fd = p[0], started = time.tick_now(), wait = wait}
	return true
}

// sig to the child's group. Never group 0 or 1 (killpg(0) is this core's own).
@(private = "file")
child_signal :: proc(c: ^Inst_Child, sig: posix.Signal) {
	if c.pid <= 1 do return
	posix.killpg(c.pid, sig)
	if sig == .SIGTERM && c.term_at == {} do c.term_at = time.tick_now()
	if sig == .SIGKILL do c.killed = true
}

// One turn: its output read, its deadline, its end. True: it ended and is reaped (exit set), or
// there was none. The leader is reaped only after its group got SIGKILL (helpers it left go too),
// so the group's id stays ours until then.
@(private = "file")
child_tick :: proc(c: ^Inst_Child, now: time.Tick) -> bool {
	if c.fd >= 0 {
		if _, eof := pipe_drain(c.fd, c.out[:], &c.out_n, CHILD_READ_BUDGET); eof {
			posix.close(c.fd)
			c.fd = -1
		}
	}
	if c.pid <= 0 do return true
	info: posix.siginfo_t
	exited := posix.waitid(.P_PID, posix.id_t(c.pid), &info, {.EXITED, .NOHANG, .NOWAIT}) == 0 && info.si_pid == c.pid
	if !exited {
		if c.term_at == {} && time.tick_diff(c.started, now) > c.wait {
			c.timed_out = true
			child_signal(c, .SIGTERM)
		} else if c.term_at != {} && !c.killed && time.tick_diff(c.term_at, now) >= INSTALL_KILL_WAIT {
			child_signal(c, .SIGKILL)
		}
		return false
	}
	if !c.killed do child_signal(c, .SIGKILL)
	st: i32
	if posix.waitpid(c.pid, &st, {.NOHANG}) != c.pid do return false
	c.exit = posix.WIFEXITED(st) ? int(posix.WEXITSTATUS(st)) : -1
	c.pid = 0
	if c.fd >= 0 {
		pipe_drain(c.fd, c.out[:], &c.out_n, CHILD_READ_BUDGET) // what it left, at most a budget's
		posix.close(c.fd)
		c.fd = -1
	}
	return true
}

// The child goes now: SIGKILL to its group, reaped.
@(private = "file")
child_reap_now :: proc(c: ^Inst_Child) {
	if c.pid > 1 {
		posix.killpg(c.pid, .SIGKILL)
		st: i32
		for posix.waitpid(c.pid, &st, {}) < 0 && posix.errno() == .EINTR {}
	}
	if c.fd >= 0 do posix.close(c.fd)
	c.pid, c.fd = 0, -1
}

when TEST_HOOKS {
	// Tests: every job and linger run gone, their children killed.
	machine_install_reset_for_test :: proc() {
		for j in inst.jobs {
			child_reap_now(&j.child)
			verify_abandon(j)
			work_remove(j)
			job_free(j)
		}
		clear(&inst.jobs)
		for l in inst.lingers {
			child_reap_now(&l.child)
			delete(l.name, runtime.heap_allocator())
			free(l, runtime.heap_allocator())
		}
		clear(&inst.lingers)
		install_ssh_for_test, install_curl_for_test, install_key_for_test, install_here_for_test = nil, nil, "", {}
		install_app_for_test, install_skip_dr_for_test = "", false
	}
	machine_install_job_for_test :: proc(no: u64) -> (phase: Machine_Job, note: string, copied, sent: bool, child: posix.pid_t) {
		j, _ := job_find(no)
		if j == nil do return
		return j.phase, j.note, j.copied, j.sent, j.child.pid
	}
}

// ---- Linux: the install's "let other machines connect" ----
//
// `install --data DIR --allow-hubs` (only what another machine's Deckhand runs over ssh, for the
// user who asked there) writes <data>/machines-reachable.grant; the core's next start takes it
// (once: removed first) and turns Settings › Machines › Allow other machines to connect on, as if
// the user had: a headless core has no window for it. Linux only (compiled out elsewhere). Taken
// only if it is a regular file (no link followed), this user's, 0600. Residual: any process of
// this user on that machine could write it, as it could edit workspace.json; on Linux the same
// user is the trust boundary (§8.3).

MACHINES_GRANT_FILE :: "machines-reachable.grant"

machines_reachable_grant_write :: proc(data: string) -> string {
	when ODIN_OS != .Linux {
		return "only a Linux core takes --allow-hubs"
	} else {
		p := strings.clone_to_cstring(upath(data, MACHINES_GRANT_FILE), context.temp_allocator)
		posix.unlink(p)
		fd := posix.open(p, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
		if fd < 0 do return fmt.tprintf("cannot write %s: %s", string(p), posix.strerror(posix.errno()))
		posix.close(fd)
		return ""
	}
}

// At serve's start, after the saved settings (serve.odin): the grant, if there, taken once.
machines_reachable_grant_take :: proc() {
	when ODIN_OS == .Linux {
		if home_root == "" do return
		if machines_grant_take_at(upath(home_root, MACHINES_GRANT_FILE)) && !state.settings.machines_reachable {
			state.settings.machines_reachable = true
			persist.gen += 1 // saved with the next save
			log_ln("Deckhand: Allow other machines to connect is on (the install from another machine asked for it)")
		}
	}
}

// The grant at path: removed whatever it is; true only if it was a regular file of this user's,
// 0600, read without following a link.
machines_grant_take_at :: proc(path: string) -> bool {
	p := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(p, {.NOFOLLOW, .CLOEXEC})
	ok := false
	if fd >= 0 {
		st: posix.stat_t
		if posix.fstat(fd, &st) == .OK && posix.S_ISREG(st.st_mode) && st.st_uid == posix.getuid() && st.st_mode & {.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH} == {} do ok = true
		posix.close(fd)
	}
	posix.unlink(p)
	return ok
}
