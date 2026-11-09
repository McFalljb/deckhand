package core

// The session holder's binary (src/holder, `deckhand-core`; docs/plans/background-core.md §3,
// §7.1): where the app finds it, its install to a versioned dir under the data dir, and the
// direct spawn (test mode, DECKHAND_HOLDER_DIRECT, and the fallback of the launchd launch in
// launchd_darwin.odin).
//
//   holder_bin_find() -> path                      the bundled binary ("" = none)
//   holder_install(bin, data) -> (path, ok, why)   what to run: an installed, verified copy
//   holder_launch_direct(bin, run, data, env) -> (pid, ok, why)
//
// The bundled binary is Deckhand Core.app's main executable (scripts/bundle-app.sh, §7.1, §10.3
// M4-A); the whole bundle (the holder, the CLI, the integrations) is installed at
// <data>/core/<HOLDER_REV>-<sha12>/Deckhand Core.app, and the holder runs from there. A bare
// binary (build/deckhand-core of a DECKHAND_NO_CEF build, a test's) is installed alone, as
// <data>/core/<HOLDER_REV>-<sha12>/deckhand-core. Either way a running holder keeps its files
// even when the app is updated or rebuilt (the sha of the main executable, whose signature seals
// the rest of its bundle, keeps dev rebuilds apart; a signed binary changed in place is killed at
// its next page-in, so not even a dev build runs from build/: only test mode does). The copy is
// checked (codesign --verify --strict --deep, against the designated requirement our own
// signature gives: trust.peer_requirement, identifier dev.deckhand.core) and only then loses
// com.apple.quarantine: a quarantined binary is SIGKILLed at exec, by launchd too (S2).

import "core:c"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

import "../trust"

HOLDER_ID :: "dev.deckhand.core" // its signing identifier (build.sh, scripts/bundle-app.sh; trust.CORE_IDS)
HOLDER_BIN :: "deckhand-core"
CORE_APP :: "Deckhand Core.app" // in Deckhand.app/Contents/Helpers (scripts/bundle-app.sh)
HOLDER_REV :: 5 // the bundled holder's revision (src/holder HOLDER_REV; scripts/check-holder-rev.sh): the install dir's prefix
HOLDER_LOG :: "holder.log" // in the runtime dir: the holder's stderr
CORE_LOG :: "core.log" // in the runtime dir: a separate core's stderr (deckhand-core serve)

// The bundled binary: <exe dir>/../Helpers/Deckhand Core.app/Contents/MacOS/deckhand-core
// (Deckhand.app), else deckhand-core beside our binary (build/deckhand-core of a bare development
// build at build/deckhand, a test's). "" = none found.
holder_bin_find :: proc(allocator := context.allocator) -> string {
	exe := holder_own_exe()
	if exe == "" do return ""
	dir := filepath.dir(exe)
	cands := []string{
		fmt.tprintf("%s/../Helpers/%s/Contents/MacOS/%s", dir, CORE_APP, HOLDER_BIN),
		fmt.tprintf("%s/%s", dir, HOLDER_BIN), // build/deckhand (DECKHAND_NO_CEF)
	}
	for p in cands {
		clean, _ := filepath.clean(p, context.temp_allocator)
		if os.is_file(clean) do return strings.clone(clean, allocator)
	}
	return ""
}

// What to run for the holder: bin itself in test mode (autotest: scenes, whose holders end with
// them), else a copy in <data>/core/<rev>-<sha12>/ (reused when it is already there and
// identical), development builds included. path in the heap allocator. why: why not (bin
// unreadable, the copy fails codesign, a write failed).
holder_install :: proc(bin, data: string) -> (path: string, ok: bool, why: string) {
	if autotest_active do return strings.clone(bin), true, ""
	// the holder of an installed core (core_versions.odin) is an installed, checked copy already
	if strings.has_prefix(bin, fmt.tprintf("%s/", core_versions_dir(data))) do return strings.clone(bin), true, ""
	src, rerr := os.read_entire_file(bin, context.temp_allocator)
	if rerr != nil do return "", false, fmt.tprintf("cannot read %s: %v", bin, rerr)
	sum := holder_sha256(src)
	dir := fmt.tprintf("%s/core/%d-%s", strings.trim_right(data, "/"), HOLDER_REV, sum[:12])
	if app := holder_bundle_of(bin); app != "" do return holder_install_bundle(app, dir, sum)
	dest := fmt.tprintf("%s/%s", dir, HOLDER_BIN)
	if have, err := os.read_entire_file(dest, context.temp_allocator); err == nil && holder_sha256(have) == sum {
		holder_unquarantine(dest) // identical to one that was checked; a stray mark would kill it
		return strings.clone(dest), true, ""
	}
	if err := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User}); err != nil && !os.is_dir(dir) {
		return "", false, fmt.tprintf("cannot make %s: %v", dir, err)
	}
	tmp := holder_install_tmp(dir)
	ctmp := strings.clone_to_cstring(tmp, context.temp_allocator)
	posix.unlink(ctmp) // ours from an earlier try (the pid and number in the name)
	fd := posix.open(ctmp, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR, .IXUSR})
	if fd < 0 do return "", false, fmt.tprintf("cannot write %s: %s", tmp, posix.strerror(posix.errno()))
	rest := src
	for len(rest) > 0 {
		n := posix.write(fd, raw_data(rest), len(rest))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 {
			posix.close(fd)
			posix.unlink(ctmp)
			return "", false, fmt.tprintf("cannot write %s: %s", tmp, posix.strerror(posix.errno()))
		}
		rest = rest[n:]
	}
	posix.fsync(fd)
	posix.close(fd)
	// the copy is what runs: check it, not bin (which could change under us)
	if w := holder_verify(tmp); w != "" {
		posix.unlink(ctmp)
		return "", false, w
	}
	holder_unquarantine(tmp)
	posix.chmod(ctmp, {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH})
	if posix.rename(ctmp, strings.clone_to_cstring(dest, context.temp_allocator)) != 0 {
		posix.unlink(ctmp)
		return "", false, fmt.tprintf("cannot install %s: %s", dest, posix.strerror(posix.errno()))
	}
	return strings.clone(dest), true, ""
}

// The bundle bin is the main executable of: ".../Deckhand Core.app" for
// ".../Deckhand Core.app/Contents/MacOS/deckhand-core", else "" (a bare binary).
holder_bundle_of :: proc(bin: string) -> string {
	suffix := fmt.tprintf("/%s/Contents/MacOS/%s", CORE_APP, HOLDER_BIN)
	if !strings.has_suffix(bin, suffix) do return ""
	return bin[:len(bin) - len(suffix) + 1 + len(CORE_APP)]
}

// holder_install for a bundle: app copied whole (ditto) into a temp dir beside dir, checked
// there (the copy is what runs), its quarantine removed, then the temp dir renamed to dir. dir
// already there with the same main executable (sum): reused. The path returned is the copy's
// main executable.
holder_install_bundle :: proc(app, dir, sum: string) -> (path: string, ok: bool, why: string) {
	rel := fmt.tprintf("%s/Contents/MacOS/%s", CORE_APP, HOLDER_BIN)
	dest := fmt.tprintf("%s/%s", dir, rel)
	if have, err := os.read_entire_file(dest, context.temp_allocator); err == nil && holder_sha256(have) == sum {
		holder_unquarantine_tree(fmt.tprintf("%s/%s", dir, CORE_APP)) // identical to one that was checked
		return strings.clone(dest), true, ""
	}
	parent := filepath.dir(dir)
	if err := os.make_directory_all(parent, {.Read_User, .Write_User, .Execute_User}); err != nil && !os.is_dir(parent) {
		return "", false, fmt.tprintf("cannot make %s: %v", parent, err)
	}
	tmp := holder_install_tmp(parent)
	remove_tree(tmp) // ours from an earlier try (the pid and number in the name)
	if posix.mkdir(strings.clone_to_cstring(tmp, context.temp_allocator), posix.S_IRWXU) != .OK {
		return "", false, fmt.tprintf("cannot make %s: %s", tmp, posix.strerror(posix.errno()))
	}
	copy := fmt.tprintf("%s/%s", tmp, CORE_APP)
	if out, st := run_group({"/usr/bin/ditto", app, copy}, 60 * time.Second, merge_stderr = true); st != .Ok {
		remove_tree(tmp)
		return "", false, fmt.tprintf("cannot copy %s: %v %s", app, st, strings.trim_space(out))
	}
	// the copy is what runs: check it, not app (which could change under us)
	got, gerr := os.read_entire_file(fmt.tprintf("%s/%s", tmp, rel), context.temp_allocator)
	if gerr != nil || holder_sha256(got) != sum {
		remove_tree(tmp)
		return "", false, fmt.tprintf("%s changed while it was copied", app)
	}
	if w := holder_verify(copy); w != "" {
		remove_tree(tmp)
		return "", false, w
	}
	holder_unquarantine_tree(copy)
	if posix.rename(strings.clone_to_cstring(tmp, context.temp_allocator), strings.clone_to_cstring(dir, context.temp_allocator)) != 0 {
		e := posix.errno()
		remove_tree(tmp)
		// another install of the same build won the race: use it if it is that build
		if have, err := os.read_entire_file(dest, context.temp_allocator); err == nil && holder_sha256(have) == sum do return strings.clone(dest), true, ""
		return "", false, fmt.tprintf("cannot install %s: %s", dir, posix.strerror(e))
	}
	return strings.clone(dest), true, ""
}

// "" if path (a binary, or a bundle with everything in it) is validly signed (strict) as our own
// signature says the holder must be (trust.peer_requirement: its identifier, and under the
// self-signed identity our certificate; ad hoc: the identifier only), else why not.
holder_verify :: proc(path: string) -> string {
	text, rok := trust.peer_requirement(trust.own_signature(), trust.CORE_IDS)
	if !rok do return fmt.tprintf("the session holder %s cannot be checked: this process's own signature is unreadable", path)
	out, st := run_group({"/usr/bin/codesign", "--verify", "--strict", "--deep", "-R", fmt.tprintf("=%s", text), path}, 20 * time.Second, merge_stderr = true)
	if st == .Ok do return ""
	return fmt.tprintf("the session holder %s fails its signature check (%v): %s", path, st, strings.trim_space(out))
}

QUARANTINE_XATTR :: "com.apple.quarantine"

when ODIN_OS == .Darwin {
	foreign import xattrlib "system:System"
	@(default_calling_convention = "c")
	foreign xattrlib {
		removexattr :: proc(path: cstring, name: cstring, options: c.int) -> c.int ---
		getxattr :: proc(path: cstring, name: cstring, value: rawptr, size: c.size_t, position: u32, options: c.int) -> c.ssize_t ---
	}
	XATTR_NOFOLLOW :: 0x0001

	holder_unquarantine :: proc(path: string) {
		removexattr(strings.clone_to_cstring(path, context.temp_allocator), QUARANTINE_XATTR, XATTR_NOFOLLOW) // ENOATTR is fine
	}
	// Every file, folder and link at and below path (links not followed).
	holder_unquarantine_tree :: proc(path: string) {
		holder_unquarantine(path)
		st: posix.stat_t
		if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK || !posix.S_ISDIR(st.st_mode) do return
		entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
		if err != nil do return
		for e in entries do holder_unquarantine_tree(fmt.tprintf("%s/%s", path, e.name))
	}
	holder_quarantined :: proc(path: string) -> bool {
		return getxattr(strings.clone_to_cstring(path, context.temp_allocator), QUARANTINE_XATTR, nil, 0, 0, XATTR_NOFOLLOW) >= 0
	}
	holder_own_exe :: proc() -> string {
		buf: [4096]u8
		n := proc_pidpath(c.int(posix.getpid()), &buf[0], u32(len(buf))) // pty_posix.odin's
		if n <= 0 do return ""
		return strings.clone(string(buf[:n]), context.temp_allocator)
	}
} else {
	holder_unquarantine :: proc(path: string) {}
	holder_unquarantine_tree :: proc(path: string) {}
	holder_quarantined :: proc(path: string) -> bool {return false}
	holder_own_exe :: proc() -> string {
		p, err := os.read_link("/proc/self/exe", context.temp_allocator)
		return err == nil ? p : ""
	}
}

// The sha256 (hex) of a file's bytes, "" if unreadable. Temp.
holder_sha256_file :: proc(path: string) -> string {
	b, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? holder_sha256(b) : ""
}

holder_sha256 :: proc(data: []u8) -> string {
	sum: [sha2.DIGEST_SIZE_256]u8
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, sum[:])
	return string(hex.encode(sum[:], context.temp_allocator))
}

// The holder started as this process's child, in a session of its own: `bin hold --run run
// --data data` with env (nil = this process's), stdin /dev/null, stdout and stderr appended to <run>/holder.log, signals at
// their defaults and none blocked, no other descriptor. A thread reaps it when it exits (it is
// only ever our child while we live; after we exit launchd adopts it). Test mode and
// DECKHAND_HOLDER_DIRECT=1 use this; the launchd launch falls back to it.
holder_launch_direct :: proc(bin, run, data: string, env: []string = nil, mode := "hold") -> (pid: i32, ok: bool, why: string) {
	argv := []cstring{
		strings.clone_to_cstring(bin, context.temp_allocator),
		strings.clone_to_cstring(mode, context.temp_allocator), // hold, or serve (a separate core)
		"--run",
		strings.clone_to_cstring(run, context.temp_allocator),
		"--data",
		strings.clone_to_cstring(data, context.temp_allocator),
		nil,
	}
	envp := posix.environ
	if env != nil {
		cenv := make([]cstring, len(env) + 1, context.temp_allocator)
		for e, i in env do cenv[i] = strings.clone_to_cstring(e, context.temp_allocator)
		envp = raw_data(cenv)
	}
	log := strings.clone_to_cstring(fmt.tprintf("%s/%s", run, mode == "serve" ? CORE_LOG : HOLDER_LOG), context.temp_allocator)
	attr, fa: [512]u8 // opaque (a pointer on macOS, a struct elsewhere)
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	all, none: posix.sigset_t
	posix.sigfillset(&all)
	posix.sigemptyset(&none)
	holder_spawnattr_setsigdefault(&attr, &all)
	holder_spawnattr_setsigmask(&attr, &none)
	posix_spawnattr_setflags(&attr, i16(HOLDER_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | HOLDER_SPAWN_SETSIGDEF | HOLDER_SPAWN_SETSIGMASK))
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	holder_spawn_addopen(&fa, 0, "/dev/null", i32(posix.O_RDONLY), 0)
	holder_spawn_addopen(&fa, 1, log, transmute(i32)posix.O_Flags{.WRONLY, .CREAT, .APPEND}, 0o600)
	posix_spawn_file_actions_adddup2(&fa, 1, 2)
	p: posix.pid_t
	sync.rw_mutex_shared_lock(&fork_lock) // fork_lock, pty.odin
	err := posix.posix_spawn(&p, argv[0], &fa, &attr, raw_data(argv), envp)
	sync.rw_mutex_shared_unlock(&fork_lock)
	if err != .NONE do return 0, false, fmt.tprintf("cannot start %s: %s", bin, posix.strerror(err))
	thread.create_and_start_with_poly_data(p, proc(p: posix.pid_t) {
		st: i32
		for posix.waitpid(p, &st, {}) < 0 && posix.errno() == .EINTR {}
	}, self_cleanup = true)
	return i32(p), true, ""
}

when ODIN_OS == .Darwin {
	foreign import holderspawn "system:System"
	HOLDER_SPAWN_SETSID :: 0x0400
} else {
	foreign import holderspawn "system:c"
	HOLDER_SPAWN_SETSID :: 0x0080 // glibc
}
HOLDER_SPAWN_SETSIGDEF :: 0x04 // macOS and glibc
HOLDER_SPAWN_SETSIGMASK :: 0x08

@(default_calling_convention = "c")
foreign holderspawn {
	@(link_name = "posix_spawnattr_setsigdefault")
	holder_spawnattr_setsigdefault :: proc(attr: rawptr, set: ^posix.sigset_t) -> posix.Errno ---
	@(link_name = "posix_spawnattr_setsigmask")
	holder_spawnattr_setsigmask :: proc(attr: rawptr, set: ^posix.sigset_t) -> posix.Errno ---
	@(link_name = "posix_spawn_file_actions_addopen")
	holder_spawn_addopen :: proc(fa: rawptr, fd: i32, path: cstring, oflag: i32, mode: u16) -> posix.Errno ---
}

when ODIN_OS != .Darwin {
	// No launchd: the holder is always the direct child (Linux is not wired up for it yet).
	holder_launch :: proc(bin, run, data: string, env: []string) -> (pid: i32, ok: bool, why: string) {
		if len(run) + RUNTIME_HOLDER_NEED > SUN_PATH_MAX do return 0, false, fmt.tprintf("the runtime dir %s is too long for the session holder's socket", run)
		return holder_launch_direct(bin, run, data, env)
	}
}

// A temp name of this call's own in dir: the pid and a per-process number (two threads may
// install at once: the updater's relaunch helper and an upgrade).
holder_install_tmp :: proc(dir: string) -> string {
	@(static) seq: u64
	n := sync.atomic_add(&seq, 1)
	return fmt.tprintf("%s/.%s.%d.%d.tmp", dir, HOLDER_BIN, posix.getpid(), n)
}

// ---- a separate core's binary (deckhand-core-serve, src/coremain; §10.3 M4-C) ----

CORE_SERVE_BIN :: "deckhand-core-serve" // beside deckhand-core in Deckhand Core.app (scripts/bundle-app.sh)

// The bundled serve binary ("" = none): beside the holder's.
core_serve_bin_find :: proc(allocator := context.allocator) -> string {
	h := holder_bin_find(context.temp_allocator)
	if h == "" do return ""
	p := fmt.tprintf("%s/%s", filepath.dir(h), CORE_SERVE_BIN)
	return os.is_file(p) ? strings.clone(p, allocator) : ""
}

// What to run for a separate core: bin itself in test mode, or for a bare development build (no
// Core.app); else the serve binary of bin's Core.app installed as current in <data>/core/
// (core_versions.odin: a running core keeps its files when the app is updated or rebuilt).
core_install :: proc(bin, data: string) -> (path: string, ok: bool, why: string) {
	if autotest_active do return strings.clone(bin), true, ""
	app := holder_bundle_of(fmt.tprintf("%s/%s", filepath.dir(bin), HOLDER_BIN))
	if app == "" {
		fmt.eprintln("Deckhand: background core: no Deckhand Core.app (a bare development build): running", bin, "in place")
		return strings.clone(bin), true, ""
	}
	return core_install_app(app, data)
}
