package core

// Installed cores (docs/plans/background-core.md §7.1, §10.3 M4-E): `deckhand-core-serve install`
// and `check`.
//
//   <data>/core/<version>-<sha12>/Deckhand Core.app   one installed copy per build: <version> is
//                                                    Core.app's (dev for a development build),
//                                                    <sha12> the hash of its two binaries
//   <data>/core/current, <data>/core/previous        symlinks to one of those, switched by rename
//
// core_install_app copies a Core.app there (holder_install's bundle copy: ditto into a temp dir,
// checked against the designated requirement our own signature gives, then its quarantine
// stripped, then renamed into place), points `current` at it and `previous` at what `current` was,
// and collects the rest: a version is removed when it is neither of those and nothing runs from
// it (no process has a path in it in its argv: the holder, a core, a pi with an integration's
// extension). The holder of an installed core runs in place (holder_install leaves a binary under
// <data>/core/ alone).
//
// check (core_check_json): what a core is, for the old core of a handover to read before it hands
// over: its version, generation, snapshot formats, holder_rev, holder wire and build.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:strconv"
import "core:sys/posix"
import "core:time"

import cw "../corewire"
import hw "../holderwire"

CORE_VERSIONS_DIR :: "core"
CORE_CURRENT :: "current"
CORE_PREVIOUS :: "previous"
CORE_USE_PREVIOUS :: "use-previous" // the user's Use previous core: the current key it turned from

// <data>/core
core_versions_dir :: proc(data: string) -> string {
	return fmt.tprintf("%s/%s", strings.trim_right(data, "/"), CORE_VERSIONS_DIR)
}

// The sha256 (hex) of a Core.app's two binaries (the holder's and serve's, beside each other in
// dir), the install's key; "" if either is unreadable.
core_pair_sum :: proc(dir: string) -> string {
	hs, herr := os.read_entire_file(fmt.tprintf("%s/%s", dir, HOLDER_BIN), context.temp_allocator)
	ss, serr := os.read_entire_file(fmt.tprintf("%s/%s", dir, CORE_SERVE_BIN), context.temp_allocator)
	if herr != nil || serr != nil do return ""
	both := strings.concatenate({holder_sha256(hs), holder_sha256(ss)}, context.temp_allocator)
	return holder_sha256(transmute([]u8)both)
}

// The build a serve binary is (the hello's and check's `build`): the first 12 of core_pair_sum
// of its dir ("" unknown). Temp.
core_build_of :: proc(serve: string) -> string {
	sum := core_pair_sum(filepath.dir(serve))
	return sum == "" ? "" : sum[:12]
}

// This process's build (a serve core's): read once.
core_build :: proc() -> string {
	@(static) value: string
	@(static) done: bool
	if !done {
		done = true
		if exe := executable_path(); exe != "" do value = strings.clone(core_build_of(exe))
	}
	return value
}

// A Core.app's install dir name: "<version>-<sha12>" (version "dev" when its Info.plist has no
// release version). "" when its binaries are unreadable.
core_key :: proc(app: string) -> string {
	sum := core_pair_sum(fmt.tprintf("%s/Contents/MacOS", app))
	if sum == "" do return ""
	v := plist_value(fmt.tprintf("%s/Contents/Info.plist", app), "CFBundleShortVersionString")
	if _, ok := cw.version_parse(v); !ok do v = "dev"
	return fmt.tprintf("%s-%s", v, sum[:12])
}

// Installs app (a Deckhand Core.app) into <data>/core/<key>/, makes it current (the old current
// becomes previous) and collects what is unused. serve: the installed copy's deckhand-core-serve.
core_install_app :: proc(app, data: string) -> (serve: string, ok: bool, why: string) {
	key := core_key(app)
	if key == "" do return "", false, fmt.tprintf("cannot read %s", app)
	vdir := core_versions_dir(data)
	dir := fmt.tprintf("%s/%s", vdir, key)
	sum := holder_sha256_file(fmt.tprintf("%s/Contents/MacOS/%s", app, HOLDER_BIN))
	p, iok, iwhy := holder_install_bundle(app, dir, sum)
	if !iok do return "", false, iwhy
	delete(p)
	serve = fmt.tprintf("%s/%s/Contents/MacOS/%s", dir, CORE_APP, CORE_SERVE_BIN)
	if got := core_pair_sum(filepath.dir(serve)); len(got) < 12 || got[:12] != key[len(key) - 12:] do return "", false, fmt.tprintf("%s changed while it was copied", app)
	if w := core_make_current(vdir, key); w != "" do return "", false, w
	core_collect(vdir, core_in_use())
	return strings.clone(serve), true, ""
}

// current -> key, and previous -> what current was (unless that was key already). "" = done.
core_make_current :: proc(vdir, key: string) -> string {
	old := core_link_read(vdir, CORE_CURRENT)
	if old == key do return ""
	os.remove(fmt.tprintf("%s/%s", vdir, CORE_USE_PREVIOUS)) // another version: Use previous core ends
	if old != "" && !core_link_set(vdir, CORE_PREVIOUS, old) do return fmt.tprintf("cannot point %s/%s at %s", vdir, CORE_PREVIOUS, old)
	if !core_link_set(vdir, CORE_CURRENT, key) do return fmt.tprintf("cannot point %s/%s at %s", vdir, CORE_CURRENT, key)
	return ""
}

// Use previous core (the palette's, or the window's offer when no core comes up): sticky while
// current stays the build the user turned from; making another build current ends it
// (core_make_current). No timer: only the user's choice and an install change it.
core_use_previous_set :: proc(data: string) -> string {
	vdir := core_versions_dir(data)
	cur := core_link_read(vdir, CORE_CURRENT)
	if cur == "" || core_serve_of(data, CORE_PREVIOUS) == "" do return "no previous core is installed"
	if err := os.write_entire_file(fmt.tprintf("%s/%s", vdir, CORE_USE_PREVIOUS), transmute([]u8)cur); err != nil do return fmt.tprintf("cannot write %s/%s", vdir, CORE_USE_PREVIOUS)
	return ""
}

// The serve binary to run while Use previous core holds (the marker names current), else "". Temp.
core_use_previous_serve :: proc(data: string) -> string {
	vdir := core_versions_dir(data)
	cur := core_link_read(vdir, CORE_CURRENT)
	b, err := os.read_entire_file(fmt.tprintf("%s/%s", vdir, CORE_USE_PREVIOUS), context.temp_allocator)
	if err != nil || cur == "" || strings.trim_space(string(b)) != cur do return ""
	return core_serve_of(data, CORE_PREVIOUS)
}

// The serve binary that <data>/core/<which> (current or previous) points at, "" if none. Temp.
core_serve_of :: proc(data, which: string) -> string {
	vdir := core_versions_dir(data)
	key := core_link_read(vdir, which)
	if key == "" do return ""
	p := fmt.tprintf("%s/%s/%s", vdir, key, core_serve_rel())
	return os.is_file(p) ? p : ""
}

// The serve binary's path inside an install dir: in its Core.app on macOS, alone on Linux
// (launch_linux.odin). Temp.
core_serve_rel :: proc() -> string {
	when ODIN_OS == .Linux do return CORE_SERVE_BIN
	return fmt.tprintf("%s/Contents/MacOS/%s", CORE_APP, CORE_SERVE_BIN)
}

// What <vdir>/<name> points at: a key (one path element), else "".
core_link_read :: proc(vdir, name: string) -> string {
	t, err := os.read_link(fmt.tprintf("%s/%s", vdir, name), context.temp_allocator)
	if err != nil || t == "" || strings.contains_rune(t, '/') || t == "." || t == ".." do return ""
	return t
}

// Points <vdir>/<name> at key: a new link beside it, renamed over it.
@(private = "file")
core_link_set :: proc(vdir, name, key: string) -> bool {
	tmp := fmt.tprintf("%s/.%s.%d.tmp", vdir, name, posix.getpid())
	ctmp := strings.clone_to_cstring(tmp, context.temp_allocator)
	posix.unlink(ctmp)
	if posix.symlink(strings.clone_to_cstring(key, context.temp_allocator), ctmp) != .OK do return false
	if posix.rename(ctmp, strings.clone_to_cstring(fmt.tprintf("%s/%s", vdir, name), context.temp_allocator)) != 0 {
		posix.unlink(ctmp)
		return false
	}
	return true
}

// Every process's command line (this user's and others': ps shows them all), one per line. Temp.
core_in_use :: proc() -> string {
	argv := []string{"/bin/ps", "-axww", "-o", "args="}
	when ODIN_OS == .Linux do argv = {"ps", "-e", "-ww", "-o", "args="} // procps
	out, st := run_group(argv, 10 * time.Second)
	return st == .Ok ? out : "?" // unknown: nothing is collected
}

// Removes every dir in vdir that current and previous don't point at and that no command line in
// in_use names ("<vdir>/<name>/"). Pure but for the file system (core_versions_test.odin).
core_collect :: proc(vdir, in_use: string) {
	if in_use == "?" do return
	real := "" // the command lines may name it by its resolved path
	if r := posix.realpath(strings.clone_to_cstring(vdir, context.temp_allocator), nil); r != nil {
		real = strings.clone(string(r), context.temp_allocator)
		posix.free(r)
	}
	keep := []string{core_link_read(vdir, CORE_CURRENT), core_link_read(vdir, CORE_PREVIOUS)}
	entries, err := os.read_all_directory_by_path(vdir, context.temp_allocator)
	if err != nil do return
	next: for e in entries {
		if e.name == CORE_CURRENT || e.name == CORE_PREVIOUS || strings.has_prefix(e.name, ".") do continue
		for k in keep do if k == e.name do continue next
		st: posix.stat_t
		if posix.lstat(strings.clone_to_cstring(e.fullpath, context.temp_allocator), &st) != .OK || !posix.S_ISDIR(st.st_mode) do continue
		if strings.contains(in_use, fmt.tprintf("%s/%s/", vdir, e.name)) do continue
		if real != "" && strings.contains(in_use, fmt.tprintf("%s/%s/", real, e.name)) do continue
		log_ln("Deckhand: background core: removing an unused version,", e.fullpath)
		remove_tree(e.fullpath)
	}
}

// ---- check ----

Core_Check :: struct {
	version:     string, // "" for a development build
	generation:  i64,
	snapshot:    []string,
	holder_rev:  i64,
	holder_wire: i64,
	build:       string,
}

// `deckhand-core-serve check`'s line: this core's facts.
core_check_json :: proc() -> string {
	c := Core_Check{version = core_version(), generation = cw.GENERATION, snapshot = SNAPSHOT_FORMATS[:], holder_rev = HOLDER_REV, holder_wire = hw.WIRE, build = core_build()}
	b, _ := json.marshal(c, {}, context.temp_allocator)
	return string(b)
}

// Runs `serve check` (an installed core's binary) and reads its line. Temp.
core_check :: proc(serve: string) -> (c: Core_Check, ok: bool, why: string) {
	out, st := run_group({serve, "check"}, 10 * time.Second)
	if st != .Ok do return {}, false, fmt.tprintf("%s check: %v", serve, st)
	line := strings.trim_space(out)
	gen, gok := strconv.parse_i64(json_path(line, "generation"))
	if !gok || gen <= 0 do return {}, false, fmt.tprintf("%s check: not its answer", serve)
	c = {version = json_path(line, "version"), generation = gen, build = json_path(line, "build")}
	c.holder_rev, _ = strconv.parse_i64(json_path(line, "holder_rev"))
	c.holder_wire, _ = strconv.parse_i64(json_path(line, "holder_wire"))
	snaps := make([dynamic]string, context.temp_allocator)
	for f in SNAPSHOT_FORMATS do if strings.contains(json_path(line, "snapshot"), fmt.tprintf("%q", f)) do append(&snaps, f)
	c.snapshot = snaps[:]
	return c, true, ""
}
