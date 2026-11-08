package main

// Deckhand updates itself (docs/GUIDE.md "Updates", docs/DEVELOPING.md "Update signing").
//
//   check     a minute after start and then about once a day while running (setting
//             update_check, on by default), and on "Check for Updates…": GET the latest
//             published release of UPDATE_REPO (update_core.odin) from GitHub's API with curl, nothing
//             sent but "User-Agent: Deckhand/<version>". Failures are only logged
//             (commands.log, the update_checked event).
//   offer     a newer X.Y.Z (no pre-releases, not the skipped one): a bar over the centre
//             (ui_update.odin) with Release notes, Skip this version, Later and Update.
//             Nothing is downloaded or installed without the user's click.
//   prepare   (Update, the user's) a worker downloads the zip, its .sig and .sha256 into a
//             private folder in the data dir, checks size, SHA-256 and the Ed25519
//             signature (src/updatesig, src/update_key.odin) BEFORE unpacking, unpacks
//             with ditto, checks the names, links, bundle id, version and codesign, and
//             copies the bundle next to the running one (.deckhand-update-<v>.app).
//   install   (Restart to update, the user's; confirmed while anything runs) the running
//             bundle is renamed to <name>.app.old-<v>, the new one renamed into place, a
//             detached /bin/sh waits for this process to exit and opens the new app, and
//             Deckhand quits. The next start removes the old bundle.
//
// Agents can read the state (get_state "update") but cannot check, download or install:
// every update command is the user's (command_table.odin).
//
// Test mode: no checks unless PI_DESK_UPDATE_URL points at a fixture (file://), and then
// PI_DESK_UPDATE_DOWNLOAD (the download prefix), PI_DESK_UPDATE_VERSION (the running
// version) and PI_DESK_UPDATE_APP (a fake installed bundle, never in /Applications) stand
// in; the test key is accepted and the relaunch is only logged.

import "base:runtime"
import "core:encoding/json"
import jg "jsonguard"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import sig "updatesig"

UPDATE_START_DELAY :: 60 * time.Second
UPDATE_TICK_EVERY :: 30 * time.Minute
UPDATE_FILE :: "update.json"

Update_Phase :: enum u8 {
	None,
	Checking,
	Downloading, // download and checks (the worker)
	Ready, // the new bundle waits next to the running one
	Failed, // the last Update failed: message says why
	Installed, // test mode: swapped, relaunch logged
}
UPDATE_PHASE_NAMES := [Update_Phase]string {
	.None        = "none",
	.Checking    = "checking",
	.Downloading = "downloading",
	.Ready       = "ready",
	.Failed      = "failed",
	.Installed   = "installed",
}

Update_State :: struct {
	// the running pi-desk (Update_Env, from the timer thread at start)
	known:      bool, // Update_Env arrived
	current:    string, // its version ("" = unknown: a development build; no checks)
	bundle:     string, // the bundle to replace ("" = cannot: why_not)
	why_not:    string,
	// saved in <data dir>/update.json
	checks_off: bool,
	last_ok:    i64, // unix seconds of the last good check
	last_try:   i64,
	skipped:    string,
	backup:     string, // the old bundle, removed once the new version has started twice
	backup_for: string, // the version that replaced it
	backup_starts: int, // starts of that version so far
	staged:     string, // a prepared bundle next to the running one
	cdhash:     string, // the staged bundle's CDHash, as its signature names it
	// this run
	phase:      Update_Phase,
	release:    Release, // the latest release seen
	offered:    bool, // newer and not skipped
	dismissed:  bool, // Later: the bar hides until the next offer
	manual:     bool, // the running check is the user's: say the outcome
	message:    string, // why the last Update failed, or the last check's error
	test:       bool, // test mode with a fixture URL
	url:        string, // the release JSON's URL
	download:   string, // the download prefix (+ tag/name)
}
upd: Update_State

// ---- commands ----

Update_Check :: struct {} // the user's "Check for Updates…"
Update_Skip :: struct {} // skip the offered version
Update_Later :: struct {} // hide the bar until the next offer
Update_Download :: struct {} // "Update": download and check the offered version
Update_Install :: struct { 	// "Restart to update": swap the prepared bundle in and relaunch
	confirm: string,
}
Set_Update_Check :: struct {
	on: bool,
}
// internal (workers, the timer)
Update_Env :: struct {
	version, bundle, why_not: string,
}
Update_Tick :: struct {}
Update_Checked :: struct {
	body: string, // the release JSON
	err:  string,
}
Update_Prepared :: struct {
	staged: string,
	cdhash: string, // the signed one
	err:    string,
}

// Main thread, at start (main.odin): the saved choices, leftovers of an earlier update,
// and the timer (not in test mode without a fixture URL).
update_init :: proc() {
	update_load()
	if autotest.active {
		// a release build never reads the fixture variables: no checks in its test mode
		when !PI_DESK_UPDATE_TEST do return
		u := hook_env(.Update_Url)
		if u == "" do return
		upd.test = true
		upd.url = strings.clone(u)
		upd.download = strings.clone(hook_env(.Update_Download))
	} else {
		upd.url = strings.clone(UPDATE_API_URL)
		upd.download = strings.clone(UPDATE_DOWNLOAD_URL)
	}
	Timer :: struct {
		test:          bool,
		version, app:  string, // test mode's stand-ins
		delay:         time.Duration,
	}
	h := runtime.heap_allocator()
	t := new_clone(Timer{test = upd.test, delay = UPDATE_START_DELAY}, h)
	if upd.test {
		t.version = strings.clone(hook_env(.Update_Version), h)
		t.app = strings.clone(hook_env(.Update_App), h)
		t.delay = 300 * time.Millisecond
	}
	thread.run_with_poly_data(t, proc(t: ^Timer) {
		version, bundle, why := update_env_find(t.test, t.version, t.app)
		inbox_submit(Update_Env{version = version, bundle = bundle, why_not = why}, {kind = .Internal})
		free_all(context.temp_allocator)
		time.sleep(t.delay)
		for !app.quitting {
			inbox_submit(Update_Tick{}, {kind = .Internal})
			time.sleep(t.test ? time.Hour : UPDATE_TICK_EVERY)
		}
	})
}

// The running version and the bundle pi-desk may replace (any thread; temp allocator).
update_env_find :: proc(test: bool, test_version, test_app: string) -> (version, bundle, why: string) {
	if test {
		if test_app == "" || under_applications(test_app) do return test_version, "", "test mode installs only into a fake folder, never under /Applications"
		b, w := install_decision(upath(test_app, "Contents", "MacOS", "Deckhand"), path_writable)
		return test_version, b, w
	}
	exe := executable_path()
	if exe == "" do return "", "", "cannot find Deckhand's own executable"
	b, w := install_decision(exe, path_writable)
	app := b
	if app == "" {
		// still read the version to check (a translocated copy, a read-only folder)
		macos := filepath.dir(exe)
		app = filepath.dir(filepath.dir(macos))
	}
	v := plist_value(upath(app, "Contents", "Info.plist"), "CFBundleShortVersionString")
	if pv, ok := semver_parse(v); !ok || pv.pre do v = "" // a development build ("0.1")
	return v, b, w
}

when ODIN_OS == .Darwin {
	foreign import updlib "system:System"
	@(default_calling_convention = "c")
	foreign updlib {
		_NSGetExecutablePath :: proc(buf: [^]u8, size: ^u32) -> i32 ---
	}
}

// The real path of this process's executable (temp), or "".
executable_path :: proc() -> string {
	when ODIN_OS == .Darwin {
		buf: [4096]u8
		n := u32(len(buf))
		if _NSGetExecutablePath(&buf[0], &n) != 0 do return ""
		real: [4096]u8
		r := posix.realpath(cstring(&buf[0]), &real[0])
		if r == nil do return ""
		return strings.clone(string(r), context.temp_allocator)
	} else {
		return ""
	}
}

// One key of a plist through PlistBuddy (any thread), or "".
plist_value :: proc(plist, key: string) -> string {
	out, st := run_group({"/usr/libexec/PlistBuddy", "-c", fmt.tprintf("Print :%s", key), plist}, 10 * time.Second, cap = 4096)
	if st != .Ok do return ""
	return strings.trim_space(out)
}

update_apply :: proc(cmd: Command, caller: Caller) -> (Result, bool) {
	#partial switch c in cmd {
	case Update_Env:
		update_set(&upd.current, c.version)
		update_set(&upd.bundle, c.bundle)
		update_set(&upd.why_not, c.why_not)
		upd.known = true
		update_cleanup_leftovers()
		return {ok = true}, true
	case Update_Tick:
		if !upd.known || upd.current == "" || upd.phase != .None && upd.phase != .Failed do return {ok = true}, false
		now := update_now()
		if !update_due(now, upd.last_ok, upd.last_try, !upd.checks_off) do return {ok = true}, false
		update_check_start(false)
		return {ok = true}, true
	case Update_Check:
		if upd.url == "" do return fail("update checks are off in test mode"), false
		if !upd.known do return fail("Deckhand is still starting: try again in a moment"), false
		if upd.current == "" do return fail("this is a development build: it does not update itself"), false
		if upd.phase == .Checking do return {ok = true}, false
		if upd.phase == .Downloading do return fail("an update is downloading"), false
		update_check_start(true)
		return {ok = true}, true
	case Update_Checked:
		if upd.phase == .Checking do upd.phase = .None
		manual := upd.manual
		upd.manual = false
		if c.err != "" {
			update_set(&upd.message, c.err)
			if manual do toast_show(fmt.tprintf("Could not check for updates: %s", c.err), err = true)
			return {ok = true}, true
		}
		r, why := release_parse(c.body)
		if why != "" {
			update_set(&upd.message, why)
			if manual do toast_show(fmt.tprintf("No update: %s", why), err = true)
			return {ok = true}, true
		}
		upd.last_ok = update_now()
		update_save()
		update_set(&upd.message, "")
		if (upd.phase == .Downloading || upd.phase == .Ready || upd.phase == .Installed) && r.version != upd.release.version {
			// the update under way stays; a newer one is offered once this one runs
			if manual do toast_show(fmt.tprintf("Deckhand %s is ready to install first (then %s)", upd.release.version, r.version))
			release_free(&r)
			return {ok = true}, true
		}
		if upd.release.version != r.version {
			upd.dismissed = false
			if upd.phase == .Failed do upd.phase = .None
		}
		release_free(&upd.release)
		upd.release = r
		upd.offered = update_offer(r.version, upd.current, upd.skipped)
		if manual {
			upd.dismissed = false
			if !upd.offered {
				if upd.skipped == r.version && update_offer(r.version, upd.current, "") {
					// asked by hand: the skipped version is offered again
					update_set(&upd.skipped, "")
					update_save()
					upd.offered = true
				} else do toast_show(fmt.tprintf("Deckhand %s is up to date", upd.current))
			}
		}
		return {ok = true}, true
	case Update_Skip:
		if !upd.offered do return fail("no update is offered"), false
		if upd.phase == .Downloading do return fail("the update is downloading"), false
		update_set(&upd.skipped, upd.release.version)
		upd.offered = false
		update_drop_staged()
		upd.phase = .None
		update_save()
		return {ok = true}, true
	case Update_Later:
		if upd.dismissed do return {ok = true}, false
		upd.dismissed = true
		return {ok = true}, true
	case Set_Update_Check:
		if upd.checks_off == !c.on do return {ok = true}, false
		upd.checks_off = !c.on
		update_save()
		return {ok = true}, true
	case Update_Download:
		if !upd.offered do return fail("no update is offered"), false
		if upd.phase == .Downloading || upd.phase == .Ready do return {ok = true}, false
		if why := update_cannot_install(); why != "" {
			update_set(&upd.message, why)
			upd.phase = .Failed
			return fail(why), true
		}
		update_prepare_start()
		return {ok = true}, true
	case Update_Prepared:
		if upd.phase != .Downloading do return {ok = true}, false
		if c.err != "" {
			upd.phase = .Failed
			update_set(&upd.message, c.err)
			return {ok = true}, true
		}
		upd.phase = .Ready
		update_set(&upd.staged, c.staged)
		update_set(&upd.cdhash, c.cdhash)
		update_set(&upd.message, "")
		update_save()
		return {ok = true}, true
	case Update_Install:
		if upd.phase != .Ready || upd.staged == "" do return fail("no update is ready to install"), false
		if upd.bundle == "" do return fail(upd.why_not), false
		if job_sheet_holds_quit() do return fail("the job sheet has changes: discard them first (Cancel or Esc), then restart to update"), true
		// keep_sessions: what the session holder keeps carries on through the update (§7.4), so
		// only what would stop is asked about
		keeps := holder_keeps_sessions()
		if quit_would_stop(keeps) || jobs_any_running() || (keeps && editors_unsaved() > 0) {
			what := fmt.tprintf("restart Deckhand to update to %s? %s", upd.release.version, update_restart_effects(keeps))
			if n := editors_unsaved(); n > 0 do what = fmt.tprintf("%s %d file%s with unsaved changes will be lost.", what, n, n == 1 ? "" : "s")
			gr, go_on, ch := confirm_gate(cmd, .App_Quit, caller, c.confirm, what, force_ask = true)
			if !go_on do return gr, ch
		}
		if why := update_swap(); why != "" {
			upd.phase = .Failed
			update_set(&upd.message, why)
			return fail(why), true
		}
		return {ok = true}, true
	}
	return fail("unknown command"), false
}

// What restarting to update does to what runs (the confirmation and the bar, ui_update.odin).
// keeps: the session holder keeps sessions through it (keep_sessions).
update_restart_effects :: proc(keeps: bool) -> string {
	browsers := false
	for s in state.open_sessions do for t in s.tabs do if _, is := t.kind.(Browser_Tab); is do browsers = true
	return update_effects_text(keeps, quit_would_stop(keeps), jobs_any_running(), held_away_any(), browsers)
}

// The words (update_effects_wording): stops: programs Deckhand runs itself (app tabs too) stop;
// away: tabs wait for a session holder this run could not reach (their programs run on in it).
update_effects_text :: proc(keeps, stops, jobs, away, browsers: bool) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if keeps do append(&parts, stops ? "Sessions kept running carry on" : "Sessions carry on")
	if stops do append(&parts, keeps ? "other tabs' programs will be stopped" : "Running sessions, shells and app tabs will be stopped")
	if jobs do append(&parts, "running jobs will be stopped")
	if away && !keeps do append(&parts, "sessions waiting for the session holder keep running in it")
	if browsers do append(&parts, "browser pages will reload")
	if len(parts) == 0 do return ""
	s := strings.join(parts[:], "; ", context.temp_allocator)
	return fmt.tprintf("%s%s.", strings.to_upper(s[:1], context.temp_allocator), s[1:])
}

// Why Update cannot go ahead here ("" = it can).
// release = false: only this copy of pi-desk (where it runs, its key), not the release.
update_cannot_install :: proc(release := true) -> string {
	if upd.bundle == "" do return upd.why_not != "" ? upd.why_not : "Deckhand cannot find its own app bundle"
	if sig.is_placeholder(update_key()) do return "this build has no update key: update from the release page"
	if release && !upd.release.has_sig do return "this release has no signature (.sig): update from the release page"
	return ""
}

update_key :: proc() -> string {
	when PI_DESK_UPDATE_TEST {
		if upd.test do return UPDATE_TEST_PUBLIC_KEY
	}
	return UPDATE_PUBLIC_KEY
}

@(private = "file")
update_set :: proc(dst: ^string, v: string) {
	if dst^ == v do return
	delete(dst^)
	dst^ = strings.clone(v)
}

update_now :: proc() -> i64 {return time.time_to_unix(time.now())}

// ---- the check ----

@(private = "file")
update_check_start :: proc(manual: bool) {
	upd.phase = .Checking
	upd.manual = manual
	upd.last_try = update_now()
	update_save()
	Job :: struct {
		url, ua: string,
		test:    bool,
	}
	h := runtime.heap_allocator()
	job := new_clone(Job{strings.clone(upd.url, h), strings.clone(update_user_agent(), h), upd.test}, h)
	thread.run_with_poly_data(job, proc(job: ^Job) {
		h := runtime.heap_allocator()
		body, err := curl_get(job.url, job.ua, job.test, UPDATE_JSON_MAX, json_api = true)
		inbox_submit(Update_Checked{body = body, err = err}, {kind = .Internal}) // copied
		delete(job.url, h)
		delete(job.ua, h)
		free(job, h)
		free_all(context.temp_allocator)
	})
}

update_user_agent :: proc() -> string {
	return fmt.tprintf("Deckhand/%s", upd.current != "" ? upd.current : "dev")
}

// curl with nothing from the user's curlrc (-q first), https only (file: in test mode),
// no cookies, no credentials; to `out` (a path) or, with out == "", the body (temp).
// Any thread.
curl_get :: proc(url, ua: string, test: bool, max: i64, out := "", json_api := false) -> (body: string, err: string) {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "/usr/bin/curl", "-q", "--silent", "--show-error", "--fail", "--location", "--max-redirs", "5")
	append(&args, "--proto", test ? "=file" : "=https", "--proto-redir", test ? "=file" : "=https")
	append(&args, "--max-filesize", fmt.tprintf("%d", max), "--connect-timeout", "20", "--max-time", out == "" ? "60" : "1800")
	append(&args, "--user-agent", ua)
	if json_api do append(&args, "--header", "Accept: application/vnd.github+json")
	if out != "" do append(&args, "--output", out)
	append(&args, "--", url)
	text, st := run_group(args[:], out == "" ? 70 * time.Second : 1810 * time.Second, cap = int(max) + 1, merge_stderr = false)
	switch st {
	case .Ok:
		if out == "" && i64(len(text)) > max do return "", "the answer is too big"
		return text, ""
	case .Timed_Out:
		return "", "timed out"
	case .Too_Big:
		return "", "the answer is too big"
	case .Start_Failed:
		return "", "cannot run curl"
	case .Failed:
	}
	return "", "the download failed (offline, or GitHub did not answer)"
}

// ---- prepare: download, check, unpack, stage (a worker) ----

@(private = "file")
Prep :: struct {
	version, tag, ua, download, key, data, bundle: string,
	size:                                          i64,
	has_sha, test:                                 bool,
}

@(private = "file")
update_prepare_start :: proc() {
	upd.phase = .Downloading
	update_set(&upd.message, "")
	h := runtime.heap_allocator()
	p := new_clone(Prep {
		version  = strings.clone(upd.release.version, h),
		tag      = strings.clone(upd.release.tag, h),
		ua       = strings.clone(update_user_agent(), h),
		download = strings.clone(upd.download, h),
		key      = strings.clone(update_key(), h),
		data     = strings.clone(update_data_dir(), h),
		bundle   = strings.clone(upd.bundle, h),
		size     = upd.release.zip_size,
		has_sha  = upd.release.has_sha,
		test     = upd.test,
	}, h)
	thread.run_with_poly_data(p, proc(p: ^Prep) {
		h := runtime.heap_allocator()
		staged, cdhash, err := update_prepare(p^)
		inbox_submit(Update_Prepared{staged = staged, cdhash = cdhash, err = err}, {kind = .Internal})
		for s in ([]string{p.version, p.tag, p.ua, p.download, p.key, p.data, p.bundle}) do delete(s, h)
		free(p, h)
		free_all(context.temp_allocator)
	})
}

// The updater's folder in the data dir (absolute).
update_data_dir :: proc() -> string {
	root := home_root
	if root == "" do return ""
	if !filepath.is_abs(root) {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		root = upath(cwd, root)
	}
	return root
}

// A private folder: made 0700, or an existing real folder of ours set to 0700.
@(private = "file")
private_dir :: proc(path: string) -> bool {
	cp := strings.clone_to_cstring(path, context.temp_allocator)
	posix.mkdir(cp, {.IRUSR, .IWUSR, .IXUSR})
	st: posix.stat_t
	if posix.lstat(cp, &st) != .OK || !posix.S_ISDIR(st.st_mode) || st.st_uid != posix.getuid() do return false
	return posix.chmod(cp, {.IRUSR, .IWUSR, .IXUSR}) == .OK
}

// Removes a path we made: a folder's tree or a file or link. Never follows a link, at
// `path` or anywhere below it (opened with O_NOFOLLOW, entries removed relative to their
// folder), and keeps going past what it cannot remove.
remove_tree :: proc(path: string) {
	if path == "" do return
	cp := strings.clone_to_cstring(path, context.temp_allocator)
	st: posix.stat_t
	if posix.lstat(cp, &st) != .OK do return
	if !posix.S_ISDIR(st.st_mode) {
		posix.unlink(cp)
		return
	}
	fd := posix.open(cp, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if fd < 0 do return
	remove_below(fd, 0)
	posix.rmdir(cp)

	// empties the folder open at fd (and closes fd)
	remove_below :: proc(fd: posix.FD, depth: int) {
		dir := posix.fdopendir(fd)
		if dir == nil {
			posix.close(fd)
			return
		}
		defer posix.closedir(dir)
		names := make([dynamic]cstring, context.temp_allocator)
		for {
			e := posix.readdir(dir)
			if e == nil do break
			n := cstring(raw_data(e.d_name[:]))
			if n == "." || n == ".." do continue
			append(&names, strings.clone_to_cstring(string(n), context.temp_allocator))
		}
		for n in names {
			st: posix.stat_t
			if posix.fstatat(fd, n, &st, {.SYMLINK_NOFOLLOW}) != .OK do continue
			if posix.S_ISDIR(st.st_mode) && depth < 256 {
				sub := posix.openat(fd, n, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
				if sub >= 0 do remove_below(sub, depth + 1)
				posix.unlinkat(fd, n, {.REMOVEDIR})
			} else {
				posix.unlinkat(fd, n, {})
			}
		}
	}
}

// The staged bundle's path for a version, next to the running bundle.
update_staged_path :: proc(bundle, version: string) -> string {
	return upath(filepath.dir(bundle), fmt.tprintf("%s%s.app", UPDATE_STAGED_PREFIX, version))
}

// Any thread. The new bundle's path next to the running one, or why not.
@(private = "file")
update_prepare :: proc(p: Prep) -> (staged, cdhash: string, err: string) {
	if p.data == "" do return "", "", "no data folder to download into"
	updates := upath(p.data, "updates")
	if !private_dir(updates) do return "", "", "cannot make a private folder for the download"
	tmpl := strings.clone_to_cstring(upath(updates, "dl-XXXXXX"), context.temp_allocator)
	d := posix.mkdtemp(transmute([^]byte)tmpl) // 0700
	if d == nil do return "", "", "cannot make a private folder for the download"
	work := strings.clone(string(d), context.temp_allocator)
	defer remove_tree(work)

	name := sig.zip_name(p.version, context.temp_allocator)
	base := fmt.tprintf("%s%s/", p.download, p.tag)
	zip := upath(work, name)
	sig_path := upath(work, "zip.sig")
	sha_path := upath(work, "zip.sha256")

	// the small files, then the zip (its size from the release, exactly)
	if _, e := curl_get(fmt.tprintf("%s%s.sig", base, name), p.ua, p.test, UPDATE_SMALL_MAX, out = sig_path); e != "" do return "", "", fmt.tprintf("the signature: %s", e)
	if p.has_sha {
		if _, e := curl_get(fmt.tprintf("%s%s.sha256", base, name), p.ua, p.test, UPDATE_SMALL_MAX, out = sha_path); e != "" do return "", "", fmt.tprintf("the checksum: %s", e)
	}
	if _, e := curl_get(fmt.tprintf("%s%s", base, name), p.ua, p.test, p.size, out = zip); e != "" do return "", "", fmt.tprintf("the download: %s", e)

	sum, size, ok := sig.file_sha256(zip)
	if !ok do return "", "", "cannot read the download"
	if size != p.size do return "", "", fmt.tprintf("the download is %d bytes, the release says %d", size, p.size)
	if p.has_sha {
		text, rerr := os.read_entire_file(sha_path, context.temp_allocator)
		if rerr != nil do return "", "", "cannot read the checksum"
		want, sok := sha256_file_parse(string(text), name)
		if !sok do return "", "", "the checksum file is not for this zip"
		if want != sum do return "", "", "the download does not match its checksum"
	}
	sig_text, serr := os.read_entire_file(sig_path, context.temp_allocator)
	if serr != nil do return "", "", "cannot read the signature"
	signed_cd, sig_b64, sok := sig.sig_file_parse(string(sig_text))
	if !sok do return "", "", "its signature file is not one Deckhand reads"
	manifest := sig.manifest(p.version, name, size, sum, signed_cd, context.temp_allocator)
	if !sig.verify(p.key, transmute([]byte)manifest, sig_b64) do return "", "", "its signature is not valid"

	// signed: unpack (names checked first, links checked after), then the bundle itself
	listing, lst := run_group({"/usr/bin/zipinfo", "-1", zip}, 60 * time.Second, cap = 64 << 20)
	if lst != .Ok do return "", "", "cannot list the zip"
	if why := zip_names_check(listing); why != "" do return "", "", why
	x := upath(work, "x")
	if !private_dir(x) do return "", "", "cannot make a folder to unpack into"
	if _, st := run_group({"/usr/bin/ditto", "-x", "-k", zip, x}, 600 * time.Second, cap = 1 << 20); st != .Ok do return "", "", "cannot unpack the zip"
	os.remove(zip)
	// nothing writable by group or others (links are not followed: chmod -R is -P)
	run_group({"/bin/chmod", "-R", "go-w", x}, 120 * time.Second, cap = 1 << 20)
	if why := extract_check(x); why != "" do return "", "", why
	app := upath(x, UPDATE_APP)
	if why := bundle_check(app, p.version, signed_cd); why != "" do return "", "", why

	// next to the running bundle (same folder, so the swap is a rename)
	staged = update_staged_path(p.bundle, p.version)
	remove_tree(staged)
	if _, st := run_group({"/usr/bin/ditto", app, staged}, 600 * time.Second, cap = 1 << 20); st != .Ok {
		remove_tree(staged)
		return "", "", fmt.tprintf("cannot copy the new Deckhand next to %s", filepath.base(p.bundle))
	}
	// the quarantine flag only from the bundle that passed (ditto keeps xattrs); no flag is fine
	run_group({"/usr/bin/xattr", "-d", "-r", "com.apple.quarantine", staged}, 120 * time.Second, cap = 1 << 20)
	run_group({"/bin/chmod", "-R", "go-w", staged}, 120 * time.Second, cap = 1 << 20)
	if why := bundle_tree_check(staged); why != "" {
		remove_tree(staged)
		return "", "", why
	}
	if why := install_check(staged, p.version, signed_cd); why != "" {
		remove_tree(staged)
		return "", "", why
	}
	return strings.clone(staged, context.temp_allocator), strings.clone(signed_cd, context.temp_allocator), ""
}

// The main executable's CDHash (lower-case hex) as codesign prints it, or "".
codesign_cdhash :: proc(app: string) -> string {
	out, st := run_group({"/usr/bin/codesign", "-d", "-vvv", app}, 120 * time.Second, cap = 1 << 20, merge_stderr = true)
	if st != .Ok do return ""
	rest := out
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "CDHash=") {
			h := strings.to_lower(strings.trim_space(line[len("CDHash="):]), context.temp_allocator)
			return sig.cdhash_valid(h) ? h : ""
		}
	}
	return ""
}

// The prepared bundle, right before it replaces pi-desk: a real folder owned by this user,
// and bundle_check (codesign, bundle id, version, the signed CDHash). "" = fine.
install_check :: proc(staged, version, cdhash: string) -> string {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(staged, context.temp_allocator), &st) != .OK || !posix.S_ISDIR(st.st_mode) || st.st_uid != posix.getuid() do return "the prepared update is not a folder of yours: click Update again"
	if why := bundle_tree_check(staged); why != "" do return why
	return bundle_check(staged, version, cdhash)
}

// The bundle is pi-desk at this version, its code signature holds, and its CDHash is the
// one the release's signature names (so no file changed since it was signed).
bundle_check :: proc(app, version, cdhash: string) -> string {
	if !sig.cdhash_valid(cdhash) do return "the update has no signed CDHash"
	plist := upath(app, "Contents", "Info.plist")
	if id := plist_value(plist, "CFBundleIdentifier"); id != UPDATE_BUNDLE_ID do return fmt.tprintf("the update is not Deckhand (bundle id %q)", id)
	if v := plist_value(plist, "CFBundleShortVersionString"); v != version do return fmt.tprintf("the update's version is %q, not %s", v, version)
	exe := plist_value(plist, "CFBundleExecutable")
	if exe == "" || strings.contains_any(exe, "/\x00") do return "the update names no executable"
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(upath(app, "Contents", "MacOS", exe), context.temp_allocator), &st) != .OK || !posix.S_ISREG(st.st_mode) do return "the update's executable is missing"
	// (codesign -R 'cdhash H"…"' would do both in one run, but it refuses an ad-hoc bundle's
	// own CDHash: verify, then read the CDHash)
	if _, cst := run_group({"/usr/bin/codesign", "--verify", "--deep", "--strict", app}, 600 * time.Second, cap = 1 << 20); cst != .Ok do return "the update's code signature does not verify, or it changed since it was checked"
	if codesign_cdhash(app) != strings.to_lower(cdhash, context.temp_allocator) do return "the app does not match its signature (it changed since it was checked)"
	return ""
}

// ---- install ----

// The test mode's stand-in for the relaunch (the scene checks it).
update_relaunched: string

// Main thread: the running bundle out, the new one in, the relaunch helper, quit. On a
// failure everything goes back as it was; "" = done (pi-desk is quitting).
@(private = "file")
update_swap :: proc() -> string {
	bundle, staged := upd.bundle, upd.staged
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(staged, context.temp_allocator), &st) != .OK || !posix.S_ISDIR(st.st_mode) do return "the prepared update is gone: click Update again"
	if !staged_path_ok(staged, bundle) do return "the prepared update is not next to Deckhand"
	// right before the rename: still ours, still the signed bundle, still that version
	if why := install_check(staged, upd.release.version, upd.cdhash); why != "" {
		update_drop_staged()
		upd.phase = .Failed
		return why
	}
	// keep_sessions: the relaunch helper that takes the successor secret to the new app
	// (holder_successor.odin) is the holder binary, found and checked before anything moves
	helper := ""
	if holder_keeps_sessions() {
		if bin := holder_bin_find(context.temp_allocator); bin != "" {
			if exe, iok, iwhy := holder_install(bin, home_root); iok {
				helper = strings.clone(exe, context.temp_allocator)
				delete(exe)
			} else do fmt.eprintln("Deckhand: update: no relaunch helper (", iwhy, "): sessions are kept; the new app attaches to them as after a quit (no successor is named)")
		}
	}
	backup := fmt.tprintf("%s.old-%s", bundle, upd.current)
	remove_tree(backup) // an earlier attempt's
	update_set(&upd.backup, backup)
	update_set(&upd.backup_for, upd.release.version)
	upd.backup_starts = 0
	update_save() // so a later start removes it
	// one atomic swap where the file system has it: the new bundle in place, the old one at
	// the staged name; else two renames (a moment without a bundle)
	old_at := staged
	if !swap_paths(staged, bundle) {
		if os.rename(bundle, backup) != nil {
			update_set(&upd.backup, "")
			update_save()
			return fmt.tprintf("cannot move %s aside", filepath.base(bundle))
		}
		if os.rename(staged, bundle) != nil {
			os.rename(backup, bundle)
			update_set(&upd.backup, "")
			update_save()
			return "cannot move the new Deckhand into place"
		}
		old_at = backup
	} else if os.rename(staged, backup) == nil {
		old_at = backup
	} else {
		update_set(&upd.backup, "") // the old bundle stays at the staged name: the next start removes it
	}
	if old_at == backup do update_set(&upd.staged, "")
	update_save()
	// the helper waits for the secret our quit's handover gets (GOODBYE{handover, successor}); test
	// mode's starts nothing (the scene starts the new app: the same test binary)
	helped := false
	if helper != "" {
		new_exe := upd.test ? executable_path() : update_bundle_exe(bundle)
		run, rwhy := sock_runtime_dir_why(context.temp_allocator)
		if rwhy == "" && new_exe != "" {
			ok, why := relaunch_helper_start(helper, bundle, new_exe, run, no_open = upd.test)
			if !ok do fmt.eprintln("Deckhand: update:", why, "- relaunching without a successor")
			helped = ok
		}
	}
	if upd.test {
		delete(update_relaunched)
		update_relaunched = strings.clone(bundle)
		fmt.println("[autotest] update relaunch:", bundle, helped ? "(with the successor helper)" : "")
		upd.phase = .Installed
		if helped && platform.quit != nil do platform.quit() // the handover at quit, as for real
		return ""
	}
	if !helped && !relaunch_spawn(bundle) {
		// back as it was: the old bundle in place, the new one at its staged name
		if !swap_paths(old_at, bundle) {
			os.rename(bundle, fmt.tprintf("%s.failed", staged))
			os.rename(old_at, bundle)
			os.rename(fmt.tprintf("%s.failed", staged), staged)
		} else if old_at != staged {
			os.rename(old_at, staged)
		}
		update_set(&upd.backup, "")
		update_set(&upd.staged, staged)
		update_save()
		return "cannot start the relaunch helper"
	}
	if platform.quit != nil do platform.quit()
	return ""
}

when ODIN_OS == .Darwin {
	@(default_calling_convention = "c")
	foreign updlib {
		renamex_np :: proc(from, to: cstring, flags: u32) -> i32 ---
	}
}

// Swaps two paths in one step (macOS renamex_np RENAME_SWAP); false where the file system
// cannot (nothing moved then).
swap_paths :: proc(a, b: string) -> bool {
	when ODIN_OS == .Darwin {
		RENAME_SWAP :: 0x2
		return renamex_np(strings.clone_to_cstring(a, context.temp_allocator), strings.clone_to_cstring(b, context.temp_allocator), RENAME_SWAP) == 0
	} else {
		return false
	}
}

// The swapped-in bundle's main executable (its Info.plist's), or "".
@(private = "file")
update_bundle_exe :: proc(bundle: string) -> string {
	exe := plist_value(upath(bundle, "Contents", "Info.plist"), "CFBundleExecutable")
	if exe == "" || strings.contains_any(exe, "/\x00") do return ""
	return upath(bundle, "Contents", "MacOS", exe)
}

// A detached /bin/sh that waits for this process to exit, then opens the bundle. The pid
// and the path are arguments ($1, $2), never part of the script.
@(private = "file")
relaunch_spawn :: proc(bundle: string) -> bool {
	script :: `while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open "$2"`
	argv := []cstring {
		"/bin/sh",
		"-c",
		script,
		"deckhand-relaunch",
		strings.clone_to_cstring(fmt.tprintf("%d", posix.getpid()), context.temp_allocator),
		strings.clone_to_cstring(bundle, context.temp_allocator),
		nil,
	}
	attr, fa: [512]u8
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	posix_spawnattr_setflags(&attr, i16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", i32(posix.O_RDONLY), 0)
	posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", i32(posix.O_WRONLY), 0)
	posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", i32(posix.O_WRONLY), 0)
	env := []cstring{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", nil}
	pid: posix.pid_t
	sync.rw_mutex_shared_lock(&fork_lock) // fork_lock, pty.odin
	defer sync.rw_mutex_shared_unlock(&fork_lock)
	return posix.posix_spawn(&pid, "/bin/sh", &fa, &attr, raw_data(argv), raw_data(env)) == .NONE
}

// After Update_Env: the old bundle of an update that relaunched into this one, and a
// prepared bundle or download left from an earlier run.
@(private = "file")
update_cleanup_leftovers :: proc() {
	changed := false
	if upd.backup != "" {
		switch {
		case !backup_path_ok(upd.backup, upd.bundle):
			// not ours by name, or no bundle to compare with: forget it, touch nothing
			update_set(&upd.backup, "")
			changed = true
		case upd.current != "":
			// kept until the new version has started a second time (or, after the user went
			// back by hand, until whatever runs has: the backup is no use then)
			upd.backup_starts += 1
			if upd.backup_starts >= 2 {
				remove_tree(upd.backup)
				update_set(&upd.backup, "")
			}
			changed = true
		}
	}
	if upd.staged != "" {
		update_drop_staged()
		changed = true
	}
	if d := update_data_dir(); d != "" do remove_tree(upath(d, "updates"))
	if changed do update_save()
}

@(private = "file")
update_drop_staged :: proc() {
	if upd.staged == "" do return
	if staged_path_ok(upd.staged, upd.bundle) do remove_tree(upd.staged)
	update_set(&upd.staged, "")
	update_set(&upd.cdhash, "")
}

// ---- update.json ----

@(private = "file")
update_path :: proc() -> string {
	d := update_data_dir()
	return d != "" ? upath(d, UPDATE_FILE) : ""
}

update_load :: proc() {
	p := update_path()
	if p == "" do return
	data, err := os.read_entire_file(p, context.temp_allocator)
	if err != nil do return
	v, jerr := jg.parse(data, .JSON, parse_integers = true, allocator = context.temp_allocator) // update_save writes it
	o, ok := v.(json.Object)
	if jerr != nil || !ok do return
	if b, bok := o["checks"].(json.Boolean); bok do upd.checks_off = !bool(b)
	if n, nok := o["last_ok"].(json.Integer); nok do upd.last_ok = i64(n)
	if n, nok := o["last_try"].(json.Integer); nok do upd.last_try = i64(n)
	if s, sok := o["skip"].(json.String); sok && len(s) <= 32 do update_set(&upd.skipped, s)
	if s, sok := o["backup"].(json.String); sok && strings.has_prefix(s, "/") do update_set(&upd.backup, s)
	if s, sok := o["backup_for"].(json.String); sok && len(s) <= 32 do update_set(&upd.backup_for, s)
	if n, nok := o["backup_starts"].(json.Integer); nok do upd.backup_starts = int(clamp(n, 0, 100))
	if s, sok := o["staged"].(json.String); sok && strings.has_prefix(s, "/") do update_set(&upd.staged, s)
}

update_save :: proc() {
	p := update_path()
	if p == "" do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"checks":%v,"last_ok":%d,"last_try":%d,"skip":`, !upd.checks_off, upd.last_ok, upd.last_try)
	json_quote(&b, upd.skipped)
	strings.write_string(&b, `,"backup":`)
	json_quote(&b, upd.backup)
	strings.write_string(&b, `,"backup_for":`)
	json_quote(&b, upd.backup_for)
	fmt.sbprintf(&b, `,"backup_starts":%d,"staged":`, upd.backup_starts)
	json_quote(&b, upd.staged)
	strings.write_string(&b, "}\n")
	if e := write_atomic(p, strings.to_string(b)); e != "" do fmt.eprintln("Deckhand: could not save", p, ":", e)
}

// ---- the wire ----

// get_state's "update" (json_write.odin): what the user sees; no paths.
update_state_json :: proc(b: ^strings.Builder) {
	fmt.sbprintf(b, `{{"checks":%v,"current":`, !upd.checks_off)
	json_quote(b, upd.current)
	fmt.sbprintf(b, `,"phase":"%s","available":%v,"latest":`, UPDATE_PHASE_NAMES[upd.phase], upd.offered)
	json_quote(b, upd.release.version)
	strings.write_string(b, `,"skipped":`)
	json_quote(b, upd.skipped)
	fmt.sbprintf(b, `,"dismissed":%v,"can_install":%v,"last_check":%d,"message":`, upd.dismissed, update_cannot_install(release = false) == "", upd.last_ok)
	json_quote(b, upd.message)
	strings.write_byte(b, '}')
}

update_command_name :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case Update_Check:     return "update_check"
	case Update_Skip:      return "update_skip"
	case Update_Later:     return "update_later"
	case Update_Download:  return "update_download"
	case Update_Install:   return "update_install"
	case Set_Update_Check: return "set_update_check"
	case Update_Env:       return "update_env"
	case Update_Tick:      return "update_tick"
	case Update_Checked:   return "update_checked"
	case Update_Prepared:  return "update_prepared"
	}
	return ""
}

// The fields on the wire (events, the log), after "type": never the release body or a
// confirmation token.
update_write :: proc(b: ^strings.Builder, cmd: Command) {
	#partial switch c in cmd {
	case Set_Update_Check:
		fmt.sbprintf(b, `,"on":%v`, c.on)
	case Update_Env:
		strings.write_string(b, `,"version":`)
		json_quote(b, c.version)
		strings.write_string(b, `,"why_not":`)
		json_quote(b, c.why_not)
	case Update_Checked:
		fmt.sbprintf(b, `,"bytes":%d,"err":`, len(c.body))
		json_quote(b, c.err)
	case Update_Prepared:
		strings.write_string(b, `,"err":`)
		json_quote(b, c.err)
	}
}

update_clone :: proc(cmd: Command, a: runtime.Allocator) -> Command {
	s :: proc(v: string, a: runtime.Allocator) -> string {return strings.clone(v, a)}
	#partial switch c in cmd {
	case Update_Install:  return Update_Install{confirm = s(c.confirm, a)}
	case Update_Env:      return Update_Env{version = s(c.version, a), bundle = s(c.bundle, a), why_not = s(c.why_not, a)}
	case Update_Checked:  return Update_Checked{body = s(c.body, a), err = s(c.err, a)}
	case Update_Prepared: return Update_Prepared{staged = s(c.staged, a), cdhash = s(c.cdhash, a), err = s(c.err, a)}
	}
	return cmd
}

update_free :: proc(cmd: Command, a: runtime.Allocator) {
	#partial switch c in cmd {
	case Update_Install: delete(c.confirm, a)
	case Update_Env:
		delete(c.version, a)
		delete(c.bundle, a)
		delete(c.why_not, a)
	case Update_Checked:
		delete(c.body, a)
		delete(c.err, a)
	case Update_Prepared:
		delete(c.staged, a)
		delete(c.cdhash, a)
		delete(c.err, a)
	}
}

// Tests: the saved paths as an earlier run left them.
update_set_backup_for_test :: proc(backup, for_version: string) {
	update_set(&upd.backup, backup)
	update_set(&upd.backup_for, for_version)
	upd.backup_starts = 0
}
update_set_staged_for_test :: proc(staged: string) {
	update_set(&upd.staged, staged)
}
