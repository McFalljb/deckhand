package main

// The session holder's binary (src/holder, `deckhand-core`; docs/plans/background-core.md §3,
// §7.1): where the app finds it, its install to a versioned dir under the data dir, and the
// direct spawn (test mode, PI_DESK_HOLDER_DIRECT, and the fallback of the launchd launch in
// launchd_darwin.odin).
//
//   holder_bin_find() -> path                      the bundled binary ("" = none)
//   holder_install(bin, data) -> (path, ok, why)   what to run: an installed, verified copy
//   holder_launch_direct(bin, run, data, env) -> (pid, ok, why)
//
// Installed at <data>/core/<HOLDER_REV>-<sha12>/deckhand-core: a running holder keeps its
// binary even when the app is updated or rebuilt (the sha keeps dev rebuilds apart; a signed
// binary changed in place is killed at its next page-in, so not even a dev build runs from
// build/: only test mode does). The copy is
// checked (codesign --verify --strict, identifier dev.deckhand.core) and only then loses
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

HOLDER_ID :: "dev.deckhand.core" // its signing identifier (build.sh, scripts/bundle-app.sh)
HOLDER_BIN :: "deckhand-core"
HOLDER_REV :: 3 // the bundled holder's revision (src/holder HOLDER_REV; scripts/check-holder-rev.sh): the install dir's prefix
HOLDER_LOG :: "holder.log" // in the runtime dir: the holder's stderr

// The bundled binary: <exe dir>/../Helpers/deckhand-core (Deckhand.app), else build/deckhand-core
// beside build.sh (a bare development binary at build/deckhand). "" = none found.
holder_bin_find :: proc(allocator := context.allocator) -> string {
	exe := holder_own_exe()
	if exe == "" do return ""
	dir := filepath.dir(exe)
	cands := []string{
		fmt.tprintf("%s/../Helpers/%s", dir, HOLDER_BIN),
		fmt.tprintf("%s/%s", dir, HOLDER_BIN), // build/deckhand (PI_DESK_NO_CEF)
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
	if autotest.active do return strings.clone(bin), true, ""
	src, rerr := os.read_entire_file(bin, context.temp_allocator)
	if rerr != nil do return "", false, fmt.tprintf("cannot read %s: %v", bin, rerr)
	sum := holder_sha256(src)
	dir := fmt.tprintf("%s/core/%d-%s", strings.trim_right(data, "/"), HOLDER_REV, sum[:12])
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

// "" if path is validly signed (strict) with the holder's identifier, else why not.
holder_verify :: proc(path: string) -> string {
	req := fmt.tprintf("=identifier \"%s\"", HOLDER_ID)
	out, st := run_group({"/usr/bin/codesign", "--verify", "--strict", "-R", req, path}, 20 * time.Second, merge_stderr = true)
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
	holder_quarantined :: proc(path: string) -> bool {return false}
	holder_own_exe :: proc() -> string {
		p, err := os.read_link("/proc/self/exe", context.temp_allocator)
		return err == nil ? p : ""
	}
}

@(private = "file")
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
// PI_DESK_HOLDER_DIRECT=1 use this; the launchd launch falls back to it.
holder_launch_direct :: proc(bin, run, data: string, env: []string = nil) -> (pid: i32, ok: bool, why: string) {
	argv := []cstring{
		strings.clone_to_cstring(bin, context.temp_allocator),
		"hold",
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
	log := strings.clone_to_cstring(fmt.tprintf("%s/%s", run, HOLDER_LOG), context.temp_allocator)
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
