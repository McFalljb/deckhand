package core

// Install agy… and Update agy… (Settings › Coding agents, the Antigravity (through pi) row): Google's
// Antigravity CLI, put at ~/.local/bin/agy the way Google's own installer does
// (https://antigravity.google/cli/install.sh), with more checks and never running agy
// (docs/HARNESSES.md §3a, §6; docs/GUIDE.md).
//
//   offer     macOS only (the checks below are macOS's). Install when no agy is found and nothing
//             is at ~/.local/bin/agy; Update when the agy found IS ~/.local/bin/agy (a regular file)
//             and its known version is older than AGY_RECOMMENDED_VERSION. An agy elsewhere is
//             someone else's to update (agy_install_offer).
//   ask       install_agy is the user's at this Mac (User_Here) and always asks first (the bar):
//             what is downloaded and from where, what is checked, where it goes, that agy is not run.
//   run       a worker (never the core's tick):
//               1. the manifest: GET AGY_MANIFEST_BASE<platform>.json with curl (https only, no
//                  redirects, at most AGY_MANIFEST_MAX bytes); {"version","url","sha512"} read
//                  strictly: version N.N.N, at least AGY_MIN_VERSION (an update: newer than the one
//                  installed); sha512 128 hex; url exactly
//                  AGY_DOWNLOAD_PREFIX<version>-<digits>/<folder>/<file> for this Mac (t3code's
//                  check, antigravityCliRelease.ts).
//               2. a private folder (mkdtemp, 0700) INSIDE ~/.local/bin, .agy-install-XXXXXX: the
//                  same volume as the target, so the last step is one rename (or link), and nothing
//                  of the download is ever outside a folder only this user can open.
//               3. the tarball (at most AGY_TARBALL_MAX bytes, https only, no redirects), then its
//                  SHA-512 against the manifest's, BEFORE anything reads it.
//               4. tar: listed first (exactly one member, `antigravity`, a regular file), then that
//                  member alone extracted into an empty private folder (no owner, xattrs, ACLs,
//                  flags or mac metadata; a file size limit), then checked again by lstat (one
//                  regular file, at most AGY_BINARY_MAX bytes).
//               5. codesign --verify --strict against Google's Developer ID requirement (team
//                  EQHXZ8M8AV), codesign -dvv's first Authority and TeamIdentifier, and spctl
//                  (Gatekeeper: accepted, source=Notarized Developer ID), all before the quarantine
//                  flag is removed.
//               6. chmod 0755, then into place: an install by link(2) (fails if anything appeared
//                  at ~/.local/bin/agy meanwhile: never overwritten), an update by rename(2) over
//                  the file it replaces, checked again first (still a regular file of ours, the
//                  size and mtime it had when the user clicked).
//             The private folder goes on every path (defer); any failure leaves nothing at
//             ~/.local/bin/agy that was not there before, and says why (the row's detail, a toast).
//   after     <data dir>/antigravity/agy-seen.json as the extension writes it (noteAgySeen:
//             path, size, mtime in seconds, version), so the checklist shows the version without
//             running agy; the checklist is looked at again.
//
// Never: sudo, `agy install` (Google's installer runs it: it edits shell profiles), running agy, or
// writing outside ~/.local/bin and that data file, but accounts.json's agyPath, set under its lock
// when ~/.local/bin is not on the PATH tabs get (agy_accounts_set_path), so pi finds agy there.
//
// Test mode never downloads from Google: DECKHAND_TEST_AGY_RELEASE (file:///dir/: dir/manifests/
// <platform>.json and dir/antigravity-cli/… in place of the two hosts) and DECKHAND_TEST_AGY_BIN_DIR
// (the folder in place of ~/.local/bin) must both be set, or nothing is offered;
// DECKHAND_TEST_AGY_SIGNED=1 stands in for step 5's verdict (a fixture cannot be Google's). Unit tests
// call agy_install_run with their own folders (agy_test_dir for the offer).

import "base:runtime"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import jg "../jsonguard"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"

AGY_MANIFEST_HOST :: "antigravity-cli-auto-updater-974169037036.us-central1.run.app"
AGY_MANIFEST_BASE :: "https://" + AGY_MANIFEST_HOST + "/manifests/"
AGY_DOWNLOAD_HOST_PATH :: "storage.googleapis.com/antigravity-public/antigravity-cli/"
AGY_DOWNLOAD_PREFIX :: "https://" + AGY_DOWNLOAD_HOST_PATH
AGY_TEAM_ID :: "EQHXZ8M8AV"
AGY_AUTHORITY :: "Developer ID Application: Google LLC (" + AGY_TEAM_ID + ")"
// Developer ID (the intermediate's and the leaf's marker OIDs, as Apple's own designated
// requirements for Developer ID say) of Google's team
AGY_REQUIREMENT :: `anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "` + AGY_TEAM_ID + `"`
AGY_MANIFEST_MAX :: 16 * 1024
AGY_TARBALL_MAX :: 512 << 20 // 1.5.18's is 86 MB
AGY_BINARY_MAX :: 768 << 20 // 1.5.18's is 229 MB
AGY_MEMBER :: "antigravity" // the tarball's one member (install.sh)
AGY_TEMP_PREFIX :: ".agy-install-"

// What the row's button offers (agy_install_offer).
Agy_Offer :: enum u8 {
	None,
	Install,
	Update,
}

Agy_Install_Phase :: enum u8 {
	None,
	Running,
	Done,
	Failed,
}

// The run as the row shows it (a separate core's window reads it from state.live.agy).
Agy_Install_Live :: struct {
	phase:   Agy_Install_Phase,
	step:    string, // Running: what it does now
	message: string, // Failed: why
	version: string, // Done: what it installed
}

agy_inst: Agy_Install_Live // the core's (heap strings)
@(private = "file")
agy_run_target: string // the running install's ~/.local/bin/agy (heap)

// The user's Install agy… / Update agy… (the row's button): confirmed first, always.
Install_Agy :: struct {
	confirm: string `cmd:"omit,red=token"`,
}
// internal: the worker's progress and its end
Agy_Install_Step :: struct {
	step: string,
}
Agy_Install_Done :: struct {
	version: string,
	err:     string,
}

// ---- where, and what is offered ----

// Unit tests: the folder in place of ~/.local/bin ("" = none: nothing is offered), the fixture
// release (file:///dir/, as DECKHAND_TEST_AGY_RELEASE; "" = a run is refused) and the signature verdict.
agy_test_dir: string
agy_test_release: string
agy_test_signed: bool
agy_test_seen_root: string // where the command writes agy-seen.json ("" = nowhere)

// The folder agy goes into (~/.local/bin, as install.sh), or "" (nothing to offer: test mode
// without its fixture folder, or no home).
agy_install_dir :: proc() -> string {
	when TEST_HOOKS {
		if ODIN_TEST do return agy_test_dir
		if test_mode() {
			if hook_env(.Agy_Release) == "" do return "" // test mode never downloads from Google
			d := hook_env(.Agy_Bin_Dir)
			return filepath.is_abs(d) ? strings.trim_right(d, "/") : ""
		}
	}
	home := data_home(TEST_HOOKS)
	if !filepath.is_abs(home) do return ""
	return upath(home, ".local", "bin")
}

agy_install_target :: proc() -> string {
	d := agy_install_dir()
	return d != "" ? upath(d, "agy") : ""
}

// Whether ~/.local/bin is on the PATH new tabs get (pi's extension finds agy there without
// /antigravity path).
agy_install_dir_on_path :: proc() -> bool {
	d := agy_install_dir()
	if d == "" do return false
	path, _ := env_lookup(child_base_env(), "PATH")
	if test_mode() do path = detect_path()
	real := fs_real(d)
	for p in strings.split(path, ":", context.temp_allocator) {
		q := strings.trim_right(p, "/")
		if q == "" do continue
		if q == d || (real != "" && fs_real(q) == real) do return true
	}
	return false
}

// The platform's names: the manifest's, the download's folder and file (install.sh, t3code).
Agy_Platform :: struct {
	name, folder, file: string,
}

agy_platform :: proc() -> (Agy_Platform, bool) {
	when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
		return {"darwin_arm64", "darwin-arm", "cli_mac_arm64.tar.gz"}, true
	} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
		return {"darwin_amd64", "darwin-x64", "cli_mac_x64.tar.gz"}, true
	} else {
		return {}, false // Linux: no signature to check; Google's installer there
	}
}

// What the antigravity row offers for its checklist item, and a note when nothing is ("" = none).
agy_install_offer :: proc(it: Harness_Item) -> (offer: Agy_Offer, note: string) {
	if _, ok := agy_platform(); !ok do return .None, ""
	target := agy_install_target()
	if target == "" do return .None, ""
	switch it.state {
	case .Missing:
		if path_kind_l(target) != .Missing do return .None, fmt.tprintf("agy is at %s but not on your tabs' PATH: set it with /antigravity path in a pi tab", fs_display(target))
		return .Install, ""
	case .Ok, .Too_Old:
		if it.version == "" || !claude_version_below(it.version, AGY_RECOMMENDED_VERSION) do return .None, ""
		if !agy_same_file(it.where_, target) do return .None, fmt.tprintf("Installed at %s: update it to %s or newer the way you installed it", fs_display(it.where_), AGY_RECOMMENDED_VERSION)
		return .Update, ""
	case .Built_In, .Not_Loaded, .Needs_Harness, .Unchecked:
	}
	return .None, ""
}

// a is target itself: the same path, and target a regular file (not a link to someone else's agy)
@(private = "file")
agy_same_file :: proc(a, target: string) -> bool {
	if a == "" do return false
	if a != target && fs_real(a) != target do return false
	return path_kind_l(target) == .File
}

// lstat's kind (a link is .Other).
@(private = "file")
path_kind_l :: proc(p: string) -> Path_Kind {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(p, context.temp_allocator), &st) != .OK do return .Missing
	if posix.S_ISREG(st.st_mode) do return .File
	if posix.S_ISDIR(st.st_mode) do return .Dir
	return .Other
}

// The row's button and detail (harness_settings_rows): "" button = none.
agy_settings_row :: proc(it: Harness_Item) -> (button, detail: string) {
	// short: the row shows two lines at most
	v := agy_install_view()
	offer, note := agy_install_offer(it)
	detail = harness_item_text(it)
	if note != "" do detail = note
	if offer == .Install do detail = "Not installed" // the button says the rest
	#partial switch v.phase {
	case .Running:
		return "", fmt.tprintf("Installing agy: %s", v.step)
	case .Failed:
		if offer != .None do detail = fmt.tprintf("Failed: %s", v.message)
	}
	switch offer {
	case .None:
	case .Install: button = "Install agy…"
	case .Update:  button = "Update agy…"
	}
	return button, detail
}

// What the window reads: the core's (a replica's live section) or this process's.
agy_install_view :: proc() -> Agy_Install_Live {
	if replica_process do return state.live.agy
	return agy_inst
}

agy_install_live :: proc(a: runtime.Allocator) -> Agy_Install_Live {
	return {phase = agy_inst.phase, step = strings.clone(agy_inst.step, a), message = strings.clone(agy_inst.message, a), version = strings.clone(agy_inst.version, a)}
}

// The confirmation (the bar): exactly what is fetched, checked and written.
agy_confirm_text :: proc(offer: Agy_Offer, target: string) -> string {
	where_ := fs_display(target)
	head := offer == .Update ? fmt.tprintf("Update agy at %s to Google's latest release?", where_) : "Install agy, Google's Antigravity CLI?"
	return fmt.tprintf("%s Deckhand asks %s for the latest version and downloads its .tar.gz from %s, checks its SHA-512 against Google's, that agy is signed by %s and notarized by Apple, then %s %s. Deckhand does not run agy or change your shell profiles.",
		head, AGY_MANIFEST_HOST, AGY_DOWNLOAD_HOST_PATH, AGY_AUTHORITY, offer == .Update ? "replaces" : "puts it at", where_)
}

// ---- commands (main thread) ----

agy_install_apply :: proc(cmd: Command, caller: Caller) -> (Result, bool) {
	#partial switch c in cmd {
	case Install_Agy:
		if agy_inst.phase == .Running do return fail("agy is being installed: wait for it"), false
		harness_checklist_refresh(bump = false) // what is there now
		it := harness_item("antigravity")
		if it == nil do return fail("no Antigravity row in the checklist"), false
		offer, note := agy_install_offer(it^)
		if offer == .None {
			why := note != "" ? note : "Deckhand has nothing to install or update for agy here"
			return fail(why), false
		}
		target := agy_install_target()
		gr, go_on, ch := confirm_gate(cmd, .Settings_Write, caller, c.confirm, agy_confirm_text(offer, target), force_ask = true)
		if !go_on do return gr, ch
		if why := agy_install_start(offer, it^, target); why != "" {
			agy_set(&agy_inst.message, why)
			agy_inst.phase = .Failed
			window_toast(fmt.tprintf("agy was not installed: %s", why), err = true)
			agy_changed()
			return fail(why), true
		}
		return {ok = true}, true
	case Agy_Install_Step:
		if agy_inst.phase != .Running do return {ok = true}, false
		agy_set(&agy_inst.step, c.step)
		agy_changed()
		return {ok = true}, true
	case Agy_Install_Done:
		if agy_inst.phase != .Running do return {ok = true}, false
		target := strings.clone(agy_run_target, context.temp_allocator)
		if c.err != "" {
			agy_inst.phase = .Failed
			agy_set(&agy_inst.message, c.err)
			window_toast(fmt.tprintf("agy was not installed: %s", c.err), err = true)
		} else {
			agy_inst.phase = .Done
			agy_set(&agy_inst.version, c.version)
			agy_set(&agy_inst.message, "")
			seen := agy_root()
			when ODIN_TEST do seen = agy_test_seen_root // never the developer's own data dir
			if why := agy_seen_write(seen, target, c.version); why != "" do log_ln("Deckhand: agy: could not write agy-seen.json:", why)
			// not on the tabs' PATH: pi's extension is told where it is (accounts.json's agyPath)
			when !ODIN_TEST {
				if !agy_install_dir_on_path() do if why := agy_accounts_set_path(target); why != "" do log_ln("Deckhand: agy: could not set agyPath:", why)
			}
			window_toast(fmt.tprintf("agy %s is at %s", c.version, fs_display(target)))
		}
		agy_set(&agy_inst.step, "")
		harness_checklist_refresh()
		agy_changed()
		return {ok = true}, true
	}
	return fail("unknown command"), false
}

@(private = "file")
agy_set :: proc(dst: ^string, v: string) {
	if dst^ == v do return
	delete(dst^)
	dst^ = strings.clone(v)
}

@(private = "file")
agy_changed :: proc() {
	settings_gen += 1
	window_state_changed()
}

// The extension's agy-seen.json (lib/agy-accounts.ts noteAgySeen): {"path","size","mtime" (s),
// "version"}, 0600, by a temp file and a rename. "" = written.
agy_seen_write :: proc(root, bin, version: string) -> string {
	if root == "" || !filepath.is_abs(bin) || version == "" do return "nothing to write"
	k, st := path_stat(bin)
	if k != .File do return "agy is not there"
	if !os.is_dir(root) && os.make_directory_all(root, {.Read_User, .Write_User, .Execute_User}) != nil do return "cannot make its folder" // 0700, as the extension's mkdirSync
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"path":`)
	json_quote(&b, bin)
	fmt.sbprintf(&b, `,"size":%d,"mtime":%d,"version":`, st.size, st.mtime / 1_000_000_000)
	json_quote(&b, version)
	strings.write_string(&b, "}\n")
	return write_atomic(upath(root, "agy-seen.json"), strings.to_string(b))
}

// ---- the run ----

Agy_Job :: struct {
	manifest_url: string, // AGY_MANIFEST_BASE<platform>.json (test: file:)
	prefix:       string, // what the download URL must start with (AGY_DOWNLOAD_PREFIX; test: file:)
	dir:          string, // ~/.local/bin
	update:       bool, // replace dir/agy (else nothing may be there)
	expect:       Disk_Stamp, // update: dir/agy as it was at the click (size, mtime)
	installed:    string, // update: its version (the release must be newer)
	test:         bool, // file: URLs only
	ua:           string,
	platform:     Agy_Platform,
	sign:         proc(bin: string) -> string, // step 5 ("" = fine); nil = the real checks
}

// Main thread: the worker. "" = started.
@(private = "file")
agy_install_start :: proc(offer: Agy_Offer, it: Harness_Item, target: string) -> string {
	plat, ok := agy_platform()
	if !ok do return "Install agy is for macOS only"
	h := runtime.heap_allocator()
	j := new(Agy_Job, h)
	j.platform = plat
	j.dir = strings.clone(filepath.dir(target), h)
	j.update = offer == .Update
	j.installed = strings.clone(it.version, h)
	j.ua = strings.clone(update_user_agent(), h)
	j.manifest_url = strings.clone(fmt.tprintf("%s%s.json", AGY_MANIFEST_BASE, plat.name), h)
	j.prefix = AGY_DOWNLOAD_PREFIX
	if j.update {
		_, j.expect = path_stat(target)
	}
	when TEST_HOOKS {
		// test mode and unit tests: the fixture release (file:) or nothing, never Google's
		if ODIN_TEST || test_mode() {
			base := ODIN_TEST ? agy_test_release : hook_env(.Agy_Release)
			if base == "" {
				test_mode_refused("agy download")
				agy_job_free(j)
				return "test mode never downloads agy"
			}
			if !strings.has_suffix(base, "/") do base = fmt.tprintf("%s/", base)
			j.test = true
			delete(j.manifest_url, h)
			j.manifest_url = strings.clone(fmt.tprintf("%smanifests/%s.json", base, plat.name), h)
			j.prefix = strings.clone(fmt.tprintf("%santigravity-cli/", base), h)
			if (ODIN_TEST ? agy_test_signed : hook_env(.Agy_Signed) == "1") do j.sign = proc(bin: string) -> string {return ""}
		}
	}
	agy_inst.phase = .Running
	agy_set(&agy_run_target, target)
	agy_set(&agy_inst.step, "asking Google for the latest version…")
	agy_set(&agy_inst.message, "")
	agy_set(&agy_inst.version, "")
	agy_changed()
	thread.run_with_poly_data(j, proc(j: ^Agy_Job) {
		version, err := agy_install_run(j^, proc(step: string) {inbox_submit(Agy_Install_Step{step = step}, {kind = .Internal})})
		inbox_submit(Agy_Install_Done{version = version, err = err}, {kind = .Internal})
		agy_job_free(j)
		free_all(context.temp_allocator)
	})
	return ""
}

@(private = "file")
agy_job_free :: proc(j: ^Agy_Job) {
	h := runtime.heap_allocator()
	delete(j.manifest_url, h)
	if j.prefix != AGY_DOWNLOAD_PREFIX do delete(j.prefix, h)
	delete(j.dir, h)
	delete(j.installed, h)
	delete(j.ua, h)
	free(j, h)
}

// Any thread: the whole run (the header's steps). The version installed, or why nothing was.
// report: each step as the row says it (nil: none).
agy_install_run :: proc(j: Agy_Job, report: proc(step: string) = nil) -> (version: string, err: string) {
	say :: proc(report: proc(step: string), s: string) {if report != nil do report(s)}
	// macOS only (Google's signature, codesign, spctl, bsdtar's flags): nothing is touched elsewhere
	when ODIN_OS != .Darwin do return "", "Install agy is for macOS only"
	when ODIN_TEST {
		// a guard on the tests themselves: never the developer's own ~/.local/bin
		if home := account_home(); home != "" && strings.has_prefix(j.dir, upath(home, ".local")) do return "", "unit tests never install into ~/.local"
		if !j.test do return "", "unit tests never download from Google"
	}
	if j.platform.name == "" do return "", "Install agy is for macOS only"
	if !filepath.is_abs(j.dir) do return "", "no folder to install into"
	// 1. the manifest
	body, e := agy_curl(j.manifest_url, j.ua, j.test, AGY_MANIFEST_MAX)
	if e != "" do return "", fmt.tprintf("Google's release list: %s", e)
	rel, why := agy_manifest_parse(body, j.platform, j.prefix)
	if why != "" do return "", why
	if j.update && !claude_version_below(j.installed, rel.version) do return "", fmt.tprintf("Google's latest agy is %s, not newer than yours (%s)", rel.version, j.installed)
	// 2. the private folder, inside the target's folder (same volume)
	if os.make_directory_all(j.dir, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}) != nil && !os.is_dir(j.dir) do return "", fmt.tprintf("cannot make %s", fs_display(j.dir))
	dst: posix.stat_t
	if posix.stat(strings.clone_to_cstring(j.dir, context.temp_allocator), &dst) != .OK || !posix.S_ISDIR(dst.st_mode) || dst.st_uid != posix.getuid() do return "", fmt.tprintf("%s is not a folder of yours", fs_display(j.dir))
	agy_install_sweep(j.dir) // an earlier run's (a crash, a quit mid-run): one run at a time
	tmpl := strings.clone_to_cstring(upath(j.dir, AGY_TEMP_PREFIX + "XXXXXX"), context.temp_allocator)
	d := posix.mkdtemp(transmute([^]byte)tmpl) // 0700
	if d == nil do return "", fmt.tprintf("cannot make a private folder in %s", fs_display(j.dir))
	work := strings.clone(string(d), context.temp_allocator)
	defer remove_tree(work)
	// 3. the tarball, then its SHA-512 before anything reads it
	say(report, fmt.tprintf("downloading agy %s from Google…", rel.version))
	tgz := upath(work, "agy.tar.gz")
	if _, e2 := agy_curl(rel.url, j.ua, j.test, AGY_TARBALL_MAX, out = tgz); e2 != "" do return "", fmt.tprintf("the download: %s", e2)
	say(report, "checking its SHA-512…")
	sum, ok := agy_file_sha512(tgz)
	if !ok do return "", "cannot read the download"
	if sum != rel.sha512 do return "", "the download does not match the SHA-512 Google lists for it"
	// 4. one regular file, `antigravity`
	say(report, "unpacking…")
	bin, uwhy := agy_unpack(tgz, work)
	if uwhy != "" do return "", uwhy
	os.remove(tgz)
	if posix.chmod(strings.clone_to_cstring(bin, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}) != .OK do return "", "cannot make agy executable"
	// 5. Google's signature and Apple's notarization, before the quarantine flag goes
	say(report, "checking Google's signature and Apple's notarization…")
	if j.sign != nil {
		if why := j.sign(bin); why != "" do return "", why
	} else if why := agy_sign_check(bin); why != "" do return "", why
	run_group({"/usr/bin/xattr", "-d", "com.apple.quarantine", bin}, 30 * time.Second, cap = 4096) // none is fine
	// 6. into place
	say(report, fmt.tprintf("putting it at %s…", fs_display(upath(j.dir, "agy"))))
	if why := agy_place(bin, upath(j.dir, "agy"), j.update, j.expect); why != "" do return "", why
	return strings.clone(rel.version, context.temp_allocator), ""
}

// curl for the manifest and the tarball: nothing from the user's curlrc, https only (file: in
// test mode), no redirects, size-capped. To out (a path) or, with out == "", the body (temp).
@(private = "file")
agy_curl :: proc(url, ua: string, test: bool, max: i64, out := "") -> (body: string, err: string) {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "/usr/bin/curl", "-q", "--silent", "--show-error", "--fail", "--max-redirs", "0")
	append(&args, "--proto", test ? "=file" : "=https", "--proto-redir", test ? "=file" : "=https")
	append(&args, "--max-filesize", fmt.tprintf("%d", max), "--connect-timeout", "20", "--max-time", out == "" ? "60" : "1800")
	append(&args, "--user-agent", ua)
	if out != "" do append(&args, "--output", out)
	append(&args, "--", url)
	text, st := run_group(args[:], out == "" ? 70 * time.Second : 1810 * time.Second, cap = out == "" ? int(max) + 1 : 1 << 16)
	switch st {
	case .Ok:
		if out == "" && i64(len(text)) > max do return "", "the answer is too big"
		if out != "" {
			k, fst := path_stat(out)
			if k != .File do return "", "nothing was downloaded"
			if fst.size > max do return "", "the download is too big"
		}
		return text, ""
	case .Timed_Out:    return "", "timed out"
	case .Too_Big:      return "", "the answer is too big"
	case .Start_Failed: return "", "cannot run curl"
	case .Failed:
	}
	return "", "the download failed (offline, too big, or Google did not answer)"
}

Agy_Release :: struct {
	version, url, sha512: string,
}

// Google's manifest, read strictly ("" why = fine; temp). prefix: what the URL starts with.
agy_manifest_parse :: proc(body: string, plat: Agy_Platform, prefix: string) -> (r: Agy_Release, why: string) {
	bad :: "Google's release list is not one Deckhand reads"
	if len(body) > AGY_MANIFEST_MAX do return {}, "Google's release list is too big"
	v, jerr := jg.parse_string(body, .JSON, false, context.temp_allocator, max_depth = 4)
	if jerr != nil do return {}, bad
	o, ok := v.(json.Object)
	if !ok do return {}, bad
	ver, vok := o["version"].(json.String)
	url, uok := o["url"].(json.String)
	sha, sok := o["sha512"].(json.String)
	if !vok || !uok || !sok do return {}, bad
	if !agy_version_ok(ver) do return {}, fmt.tprintf("Google's release list names a version Deckhand does not read (%q)", ver)
	if claude_version_below(ver, AGY_MIN_VERSION) do return {}, fmt.tprintf("Google's latest agy is %s, older than %s", ver, AGY_MIN_VERSION)
	if len(sha) != 128 do return {}, "Google's release list has no SHA-512 Deckhand reads"
	for ch in transmute([]u8)sha {
		switch ch {
		case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		case: return {}, "Google's release list has no SHA-512 Deckhand reads"
		}
	}
	if !agy_url_ok(url, ver, plat, prefix) do return {}, "Google's release list points somewhere other than Google's own download folder for this Mac: nothing was downloaded"
	return {version = strings.clone(ver, context.temp_allocator), url = strings.clone(url, context.temp_allocator), sha512 = strings.to_lower(sha, context.temp_allocator)}, ""
}

// N.N.N, each 1 to 9 digits.
@(private = "file")
agy_version_ok :: proc(v: string) -> bool {
	parts := strings.split(v, ".", context.temp_allocator)
	if len(parts) != 3 do return false
	for p in parts {
		if len(p) == 0 || len(p) > 9 do return false
		for ch in transmute([]u8)p do if ch < '0' || ch > '9' do return false
	}
	return true
}

// Exactly prefix<version>-<digits>/<folder>/<file> (t3code's antigravityCliRelease.ts).
agy_url_ok :: proc(url, version: string, plat: Agy_Platform, prefix: string) -> bool {
	head := fmt.tprintf("%s%s-", prefix, version)
	if plat.folder == "" || !strings.has_prefix(url, head) do return false
	rest := url[len(head):]
	n := 0
	for n < len(rest) && rest[n] >= '0' && rest[n] <= '9' do n += 1
	if n == 0 || n > 32 do return false
	return rest[n:] == fmt.tprintf("/%s/%s", plat.folder, plat.file)
}

// The file's SHA-512, lower-case hex (temp).
agy_file_sha512 :: proc(path: string) -> (sum: string, ok: bool) {
	f, err := os.open(path)
	if err != nil do return "", false
	defer os.close(f)
	ctx: sha2.Context_512
	sha2.init_512(&ctx)
	buf := make([]byte, 1 << 20, context.temp_allocator)
	for {
		n, rerr := os.read(f, buf)
		if n > 0 do sha2.update(&ctx, buf[:n])
		if rerr == .EOF || (rerr == nil && n == 0) do break
		if rerr != nil do return "", false
	}
	d: [sha2.DIGEST_SIZE_512]byte
	sha2.final(&ctx, d[:])
	return string(hex.encode(d[:], context.temp_allocator)), true
}

// The tarball's one member, `antigravity`, extracted into work/x (0700): its path, or why not.
agy_unpack :: proc(tgz, work: string) -> (bin: string, why: string) {
	one :: "the download is not one agy program (Deckhand expects one file, antigravity)"
	names, st := run_group({"/usr/bin/tar", "-tzf", tgz}, 300 * time.Second, cap = 1 << 16)
	if st != .Ok do return "", "cannot read the download (tar)"
	if strings.trim_right(names, "\n") != AGY_MEMBER do return "", one
	long, lst := run_group({"/usr/bin/tar", "-tvzf", tgz}, 300 * time.Second, cap = 1 << 16)
	if lst != .Ok do return "", "cannot read the download (tar)"
	l := strings.trim_right(long, "\n")
	if strings.contains_rune(l, '\n') || !strings.has_prefix(l, "-") || !strings.has_suffix(l, " " + AGY_MEMBER) do return "", one
	x := upath(work, "x")
	if posix.mkdir(strings.clone_to_cstring(x, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR}) != .OK do return "", "cannot make a folder to unpack into"
	// the member alone, nothing but its bytes and mode; no file past AGY_BINARY_MAX (ulimit -f, 512-byte blocks)
	script :: `ulimit -f "$1" && exec /usr/bin/tar -xzf "$2" -C "$3" --no-same-owner --no-xattrs --no-acls --no-fflags --no-mac-metadata -- "$4"`
	if _, xst := run_group({"/bin/sh", "-c", script, "sh", fmt.tprintf("%d", AGY_BINARY_MAX / 512 + 1), tgz, x, AGY_MEMBER}, 600 * time.Second, cap = 1 << 16); xst != .Ok do return "", "cannot unpack the download (or agy is too big)"
	// exactly one entry, a regular file of ours
	dir := posix.opendir(strings.clone_to_cstring(x, context.temp_allocator))
	if dir == nil do return "", "cannot read what was unpacked"
	count := 0
	for {
		e := posix.readdir(dir)
		if e == nil do break
		n := string(cstring(raw_data(e.d_name[:])))
		if n == "." || n == ".." do continue
		count += 1
		if n != AGY_MEMBER do count += 100
	}
	posix.closedir(dir)
	if count != 1 do return "", one
	bin = upath(x, AGY_MEMBER)
	sb: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(bin, context.temp_allocator), &sb) != .OK || !posix.S_ISREG(sb.st_mode) || sb.st_uid != posix.getuid() || sb.st_nlink != 1 do return "", one
	if i64(sb.st_size) > AGY_BINARY_MAX || sb.st_size == 0 do return "", "agy in the download is too big (or empty)"
	return bin, ""
}

// macOS: Google's Developer ID signature holds (codesign, its designated requirement for team
// EQHXZ8M8AV), and Gatekeeper accepts it as notarized (spctl). "" = fine.
agy_sign_check :: proc(bin: string) -> string {
	when ODIN_OS != .Darwin do return "Install agy is for macOS only"
	if _, st := run_group({"/usr/bin/codesign", "--verify", "--strict", fmt.tprintf("-R=%s", AGY_REQUIREMENT), bin}, 300 * time.Second, cap = 1 << 16); st != .Ok do return "agy is not signed with Google's Developer ID (" + AGY_TEAM_ID + "): nothing was installed"
	info, dst := run_group({"/usr/bin/codesign", "-d", "-vv", bin}, 120 * time.Second, cap = 1 << 16, merge_stderr = true)
	if dst != .Ok do return "cannot read agy's signature"
	if why := agy_codesign_details_check(info); why != "" do return why
	verdict, _ := run_group({"/usr/sbin/spctl", "-a", "-vv", "-t", "install", bin}, 300 * time.Second, cap = 1 << 16, merge_stderr = true)
	return agy_spctl_check(verdict)
}

// codesign -dvv's lines: the first Authority is Google's Developer ID, TeamIdentifier its team.
agy_codesign_details_check :: proc(out: string) -> string {
	authority, team := "", ""
	rest := out
	for line in strings.split_lines_iterator(&rest) {
		if authority == "" && strings.has_prefix(line, "Authority=") do authority = line[len("Authority="):]
		if strings.has_prefix(line, "TeamIdentifier=") do team = line[len("TeamIdentifier="):]
	}
	if authority != AGY_AUTHORITY || team != AGY_TEAM_ID do return fmt.tprintf("agy is signed by %q, not %s: nothing was installed", authority != "" ? authority : "nobody", AGY_AUTHORITY)
	return ""
}

// spctl -a -vv -t install's answer: accepted, and its source Notarized Developer ID.
agy_spctl_check :: proc(out: string) -> string {
	accepted, notarized := false, false
	rest := out
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if strings.has_suffix(l, ": accepted") do accepted = true
		if l == "source=Notarized Developer ID" do notarized = true
	}
	if !accepted || !notarized do return "macOS does not accept agy as notarized by Apple (spctl): nothing was installed"
	return ""
}

// The checked binary into place. Install: link(2), so anything that appeared at target is never
// overwritten; update: target still the regular file of ours it was at the click, then rename(2).
agy_place :: proc(bin, target: string, update: bool, expect: Disk_Stamp) -> string {
	cb, ct := strings.clone_to_cstring(bin, context.temp_allocator), strings.clone_to_cstring(target, context.temp_allocator)
	if !update {
		if posix.link(cb, ct) != .OK {
			if posix.errno() == .EEXIST do return fmt.tprintf("something appeared at %s meanwhile: nothing was replaced", fs_display(target))
			return fmt.tprintf("cannot put agy at %s", fs_display(target))
		}
		return ""
	}
	st: posix.stat_t
	if posix.lstat(ct, &st) != .OK || !posix.S_ISREG(st.st_mode) || st.st_uid != posix.getuid() do return fmt.tprintf("%s is no longer the agy Deckhand found: nothing was replaced", fs_display(target))
	_, now := path_stat(target)
	if now.size != expect.size || now.mtime != expect.mtime do return fmt.tprintf("%s changed since you clicked: nothing was replaced", fs_display(target))
	if posix.rename(cb, ct) != 0 do return fmt.tprintf("cannot replace %s", fs_display(target))
	return ""
}

// Leftover private folders in d (~/.local/bin) from an earlier run: ours by owner and name.
// Called by a run before it makes its own (a core runs one at a time: agy_inst.phase).
agy_install_sweep :: proc(d: string) {
	for name in agy_temp_names(d) {
		p := upath(d, name)
		st: posix.stat_t
		if posix.lstat(strings.clone_to_cstring(p, context.temp_allocator), &st) == .OK && posix.S_ISDIR(st.st_mode) && st.st_uid == posix.getuid() do remove_tree(p)
	}
}

@(private = "file")
agy_temp_names :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	d := posix.opendir(strings.clone_to_cstring(dir, context.temp_allocator))
	if d == nil do return out[:]
	defer posix.closedir(d)
	for {
		e := posix.readdir(d)
		if e == nil do break
		name := string(cstring(raw_data(e.d_name[:])))
		if strings.has_prefix(name, AGY_TEMP_PREFIX) do append(&out, strings.clone(name, context.temp_allocator))
	}
	return out[:]
}
