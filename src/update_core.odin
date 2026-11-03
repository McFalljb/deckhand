package main

// The updater's decisions, without I/O where it can be helped (update.odin runs them;
// src/update_test.odin tests them): versions, the release JSON, when to check, where
// pi-desk may replace itself, and whether an unpacked bundle is safe to look at.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

UPDATE_REPO :: "McFalljb/pi-desk"
UPDATE_API_URL :: "https://api.github.com/repos/" + UPDATE_REPO + "/releases/latest"
UPDATE_DOWNLOAD_URL :: "https://github.com/" + UPDATE_REPO + "/releases/download/" // + tag/name
UPDATE_RELEASES_URL :: "https://github.com/" + UPDATE_REPO + "/releases"
UPDATE_BUNDLE_ID :: "dev.pi-desk.app"
UPDATE_ZIP_MAX :: i64(1) << 30 // 1 GB: no release comes near it (about 340 MB)
UPDATE_SMALL_MAX :: 4096 // the .sig and the .sha256
UPDATE_JSON_MAX :: 1 << 20 // the release JSON (its notes can be long)
UPDATE_INTERVAL :: 24 * 60 * 60 // seconds between checks
UPDATE_RETRY :: 60 * 60 // after a failed check, at most one try an hour
UPDATE_EXTRACT_MAX_ENTRIES :: 200_000
UPDATE_EXTRACT_MAX_DEPTH :: 64

// A path from parts (temp allocator).
upath :: proc(parts: ..string) -> string {
	p, _ := filepath.join(parts, context.temp_allocator)
	return p
}

// ---- versions ----

Semver :: struct {
	major, minor, patch: int,
	pre:                 bool, // a "-suffix": a pre-release (never offered)
}

// "1.2.3", "v1.2.3", "1.2.3-beta.1" (pre), "1.2.3+build" (build metadata dropped).
// Numbers: digits only, no leading zeros, at most 9 digits.
semver_parse :: proc(s: string) -> (v: Semver, ok: bool) {
	t := s
	if strings.has_prefix(t, "v") do t = t[1:]
	if i := strings.index_byte(t, '+'); i >= 0 {
		if i == len(t) - 1 do return {}, false
		t = t[:i]
	}
	if i := strings.index_byte(t, '-'); i >= 0 {
		if i == len(t) - 1 do return {}, false
		v.pre = true
		t = t[:i]
	}
	parts := strings.split(t, ".", context.temp_allocator)
	if len(parts) != 3 do return {}, false
	nums: [3]int
	for p, i in parts {
		if len(p) == 0 || len(p) > 9 || (len(p) > 1 && p[0] == '0') do return {}, false
		n := 0
		for c in transmute([]byte)p {
			if c < '0' || c > '9' do return {}, false
			n = n * 10 + int(c - '0')
		}
		nums[i] = n
	}
	v.major, v.minor, v.patch = nums[0], nums[1], nums[2]
	return v, true
}

// a < b; a pre-release is below its release
semver_less :: proc(a, b: Semver) -> bool {
	if a.major != b.major do return a.major < b.major
	if a.minor != b.minor do return a.minor < b.minor
	if a.patch != b.patch do return a.patch < b.patch
	return a.pre && !b.pre
}

semver_string :: proc(v: Semver, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%d.%d.%d", v.major, v.minor, v.patch, allocator = allocator)
}

// ---- the release ----

// What /releases/latest says, checked.
Release :: struct {
	version:   string, // X.Y.Z
	tag:       string, // vX.Y.Z
	notes_url: string, // the release's page (built from the tag, never taken from the JSON)
	zip_size:  i64,
	has_sig:   bool,
	has_sha:   bool,
}

release_free :: proc(r: ^Release) {
	delete(r.version)
	delete(r.tag)
	delete(r.notes_url)
	r^ = {}
}

// The release JSON (GitHub's REST API) to a Release; err says why it is not one to offer.
// Only the fields named here are read; the asset URLs in it are not used (update.odin
// builds them from the tag and the expected names).
release_parse :: proc(body: string, allocator := context.allocator) -> (r: Release, err: string) {
	if len(body) > UPDATE_JSON_MAX do return {}, "the release answer is too big"
	v, jerr := json.parse_string(body, .JSON, parse_integers = true, allocator = context.temp_allocator)
	if jerr != nil do return {}, "the release answer is not JSON"
	o, is_obj := v.(json.Object)
	if !is_obj do return {}, "the release answer is not an object"
	if d, _ := o["draft"].(json.Boolean); d do return {}, "the latest release is a draft"
	if p, _ := o["prerelease"].(json.Boolean); p do return {}, "the latest release is a pre-release"
	tag, has_tag := o["tag_name"].(json.String)
	if !has_tag || len(tag) > 32 do return {}, "the release has no usable tag"
	ver, vok := semver_parse(tag)
	if !vok || ver.pre || !strings.has_prefix(tag, "v") || strings.contains_rune(tag, '+') do return {}, "the release's tag is not vX.Y.Z"
	version := semver_string(ver)
	if tag[1:] != version do return {}, "the release's tag is not vX.Y.Z"
	assets, has_assets := o["assets"].(json.Array)
	if !has_assets do return {}, "the release has no assets"
	zip := fmt.tprintf("pi-desk-%s-macos-arm64.zip", version)
	sig := fmt.tprintf("%s.sig", zip)
	sha := fmt.tprintf("%s.sha256", zip)
	found_zip := false
	for a in assets {
		ao, ok := a.(json.Object)
		if !ok do continue
		name, _ := ao["name"].(json.String)
		size: i64 = -1
		#partial switch s in ao["size"] {
		case json.Integer: size = i64(s)
		}
		switch name {
		case zip:
			if size <= 0 do return {}, "the release's zip has no size"
			if size > UPDATE_ZIP_MAX do return {}, "the release's zip is over 1 GB"
			r.zip_size = size
			found_zip = true
		case sig:
			r.has_sig = size > 0 && size <= UPDATE_SMALL_MAX
		case sha:
			r.has_sha = size > 0 && size <= UPDATE_SMALL_MAX
		}
	}
	if !found_zip do return {}, "the release has no macOS arm64 zip"
	r.version = strings.clone(version, allocator)
	r.tag = strings.clone(tag, allocator)
	r.notes_url = fmt.aprintf("%s/tag/%s", UPDATE_RELEASES_URL, tag, allocator = allocator)
	return r, ""
}

// Whether to offer `latest` to a pi-desk at `current`: newer, and not the version the
// user skipped.
update_offer :: proc(latest, current: string, skipped: string) -> bool {
	l, lok := semver_parse(latest)
	c, cok := semver_parse(current)
	if !lok || !cok || l.pre do return false
	if skipped != "" && skipped == latest do return false
	return semver_less(c, l)
}

// The .sha256 file ("<hex>  <name>"): its hex, if it names `name`.
sha256_file_parse :: proc(text, name: string) -> (hex: string, ok: bool) {
	line := strings.trim_space(text)
	if i := strings.index_byte(line, '\n'); i >= 0 do line = strings.trim_space(line[:i])
	sp := strings.index_any(line, " \t")
	if sp != 64 do return "", false
	h := line[:64]
	for c in transmute([]byte)h {
		switch c {
		case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		case:
			return "", false
		}
	}
	rest := strings.trim_left(line[64:], " \t*")
	if rest != name do return "", false
	return strings.to_lower(h, context.temp_allocator), true
}

// ---- when to check ----

// Unix seconds. A check is due when checks are on, the last good one is a day old, and
// the last try (good or not) an hour old. A clock that went back counts as due.
update_due :: proc(now, last_ok, last_try: i64, enabled: bool) -> bool {
	if !enabled do return false
	if last_try > now || last_ok > now do return true
	if now - last_try < UPDATE_RETRY do return false
	return now - last_ok >= UPDATE_INTERVAL
}

// ---- where pi-desk may replace itself ----

// The running bundle (from the executable's real path) and, when pi-desk cannot replace
// it, why. `writable` is posix access(W_OK) (tests pass their own).
install_decision :: proc(exe: string, writable: proc(path: string) -> bool) -> (bundle: string, why: string) {
	if strings.contains(exe, "/AppTranslocation/") {
		return "", "macOS runs this copy from a temporary read-only place (App Translocation). Move pi-desk.app to Applications with Finder, open it from there, then update"
	}
	macos := filepath.dir(exe)
	contents := filepath.dir(macos)
	bundle = filepath.dir(contents)
	if filepath.base(macos) != "MacOS" || filepath.base(contents) != "Contents" || !strings.has_suffix(bundle, ".app") || len(bundle) <= len(".app") {
		return "", "pi-desk is not running from an app bundle"
	}
	parent := filepath.dir(bundle)
	if filepath.base(parent) == "build" && os.exists(upath(parent, "..", "build.sh")) {
		return "", "this is a development build (build/pi-desk.app): rebuild it instead"
	}
	if strings.has_prefix(bundle, "/Volumes/") && !writable(parent) {
		return "", "pi-desk runs from a read-only disk image. Copy pi-desk.app to Applications, open it from there, then update"
	}
	if !writable(parent) do return "", fmt.tprintf("you cannot write to %s, where pi-desk.app is", parent)
	if !writable(bundle) do return "", fmt.tprintf("you cannot write to %s", bundle)
	return bundle, ""
}

path_writable :: proc(path: string) -> bool {
	return posix.access(strings.clone_to_cstring(path, context.temp_allocator), {.W_OK}) == .OK
}

// ---- the unpacked bundle ----

// `root` holds what the zip unpacked to: exactly one entry, `pi-desk.app`, a real folder,
// whose tree passes bundle_tree_check. "" = safe.
extract_check :: proc(root: string) -> (why: string) {
	entries, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil do return "cannot read the unpacked update"
	if len(entries) != 1 || entries[0].name != "pi-desk.app" do return "the zip does not hold exactly pi-desk.app"
	return bundle_tree_check(upath(root, "pi-desk.app"))
}

// An app bundle's tree: the bundle a real folder; inside it only folders, regular files and
// symlinks; nothing setuid or setgid; nothing writable by group or others; every symlink
// relative, inside the bundle by its text AND by its real path (links through other links
// included; a dangling link is refused). Links are read, never written through. "" = safe.
bundle_tree_check :: proc(app: string) -> (why: string) {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(app, context.temp_allocator), &st) != .OK || !posix.S_ISDIR(st.st_mode) do return "pi-desk.app in the zip is not a folder"
	if .IWGRP in st.st_mode || .IWOTH in st.st_mode do return "pi-desk.app is writable by others"
	real: [4096]u8
	rp := posix.realpath(strings.clone_to_cstring(app, context.temp_allocator), &real[0])
	if rp == nil do return "cannot read the unpacked update"
	app_real := strings.clone(string(rp), context.temp_allocator)
	count := 0
	return walk(app, app_real, "", 0, &count)

	// rel: the path below the bundle ("" = the bundle itself), "/"-separated
	walk :: proc(dir, app_real, rel: string, depth: int, count: ^int) -> string {
		if depth > UPDATE_EXTRACT_MAX_DEPTH do return "the update's folders nest too deep"
		names, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return "cannot read the unpacked update"
		for e in names {
			count^ += 1
			if count^ > UPDATE_EXTRACT_MAX_ENTRIES do return "the update has too many files"
			p := upath(dir, e.name)
			r := rel == "" ? e.name : strings.concatenate({rel, "/", e.name}, context.temp_allocator)
			st: posix.stat_t
			cp := strings.clone_to_cstring(p, context.temp_allocator)
			if posix.lstat(cp, &st) != .OK do return fmt.tprintf("cannot read %s in the update", r)
			if .ISUID in st.st_mode || .ISGID in st.st_mode do return fmt.tprintf("%s in the update is setuid or setgid", r)
			switch {
			case posix.S_ISLNK(st.st_mode):
				target, lerr := os.read_link(p, context.temp_allocator)
				if lerr != nil do return fmt.tprintf("cannot read the link %s in the update", r)
				if !link_inside(r, target) do return fmt.tprintf("the link %s in the update points outside pi-desk.app", r)
				real: [4096]u8
				rp := posix.realpath(cp, &real[0])
				if rp == nil || !strings.has_prefix(string(rp), strings.concatenate({app_real, "/"}, context.temp_allocator)) do return fmt.tprintf("the link %s in the update points outside pi-desk.app (or nowhere)", r)
			case posix.S_ISDIR(st.st_mode):
				if .IWGRP in st.st_mode || .IWOTH in st.st_mode do return fmt.tprintf("%s in the update is writable by others", r)
				if why := walk(p, app_real, r, depth + 1, count); why != "" do return why
			case posix.S_ISREG(st.st_mode):
				if .IWGRP in st.st_mode || .IWOTH in st.st_mode do return fmt.tprintf("%s in the update is writable by others", r)
			case:
				return fmt.tprintf("%s in the update is not a file, folder or link", r)
			}
		}
		return ""
	}
}

// A symlink at `rel` (below the bundle, "/"-separated) with this target stays inside the
// bundle: relative, and never climbing above the bundle at any step.
link_inside :: proc(rel, target: string) -> bool {
	if target == "" || strings.has_prefix(target, "/") || strings.contains_rune(target, 0) do return false
	stack := make([dynamic]string, context.temp_allocator)
	parts := strings.split(rel, "/", context.temp_allocator)
	for p in parts[:len(parts) - 1] do append(&stack, p) // the link's folder
	for p in strings.split(target, "/", context.temp_allocator) {
		switch p {
		case "", ".":
		case "..":
			if len(stack) == 0 do return false
			pop(&stack)
		case:
			append(&stack, p)
		}
	}
	return len(stack) > 0 // the bundle itself is not a target
}

// The tar-style names a zip listing gives (one per line): none absolute, none with a ".."
// part, all inside pi-desk.app/. "" = fine.
zip_names_check :: proc(listing: string) -> string {
	n := 0
	rest := listing
	for line in strings.split_lines_iterator(&rest) {
		if line == "" do continue
		n += 1
		if n > UPDATE_EXTRACT_MAX_ENTRIES do return "the zip has too many entries"
		if strings.has_prefix(line, "/") do return "the zip has an absolute path"
		for p in strings.split(line, "/", context.temp_allocator) do if p == ".." do return "the zip has a path with .."
		if line != "pi-desk.app/" && !strings.has_prefix(line, "pi-desk.app/") do return "the zip holds more than pi-desk.app"
	}
	if n == 0 do return "the zip is empty"
	return ""
}


// ---- paths ----

// Whether a path is /Applications or inside it, however it is spelled (//, .., a link, the
// Data volume's firmlink, case). Test mode never installs there.
under_applications :: proc(path: string) -> bool {
	is :: proc(p: string) -> bool {
		l := strings.to_lower(p, context.temp_allocator)
		for root in ([]string{"/applications", "/system/volumes/data/applications"}) {
			if l == root || strings.has_prefix(l, strings.concatenate({root, "/"}, context.temp_allocator)) do return true
		}
		return false
	}
	clean, _ := filepath.clean(path, context.temp_allocator)
	if is(clean) do return true
	// the real path of the deepest part that exists, then the rest
	head, tail := clean, ""
	for head != "/" && head != "" && head != "." {
		real: [4096]u8
		if rp := posix.realpath(strings.clone_to_cstring(head, context.temp_allocator), &real[0]); rp != nil {
			full := tail == "" ? strings.clone(string(rp), context.temp_allocator) : upath(string(rp), tail)
			return is(full)
		}
		tail = tail == "" ? filepath.base(head) : upath(filepath.base(head), tail)
		head = filepath.dir(head)
	}
	return false
}

@(private = "file")
path_plain :: proc(p: string) -> bool {
	if p == "" || !strings.has_prefix(p, "/") do return false
	clean, _ := filepath.clean(p, context.temp_allocator)
	if clean != p do return false
	for part in strings.split(p, "/", context.temp_allocator) do if part == ".." || part == "." do return false
	return true
}

@(private = "file")
release_version_ok :: proc(v: string) -> bool {
	sv, ok := semver_parse(v)
	return ok && !sv.pre && !strings.has_prefix(v, "v") && !strings.contains_rune(v, '+')
}

// update.json's staged path: <bundle's folder>/.pi-desk-update-X.Y.Z.app, plain.
staged_path_ok :: proc(path, bundle: string) -> bool {
	if bundle == "" || !path_plain(path) || !path_plain(bundle) do return false
	if filepath.dir(path) != filepath.dir(bundle) do return false
	b := filepath.base(path)
	if !strings.has_prefix(b, ".pi-desk-update-") || !strings.has_suffix(b, ".app") do return false
	return release_version_ok(b[len(".pi-desk-update-"):len(b) - len(".app")])
}

// update.json's backup path: <bundle>.old-X.Y.Z, plain.
backup_path_ok :: proc(path, bundle: string) -> bool {
	if bundle == "" || !path_plain(path) || !path_plain(bundle) do return false
	prefix := strings.concatenate({bundle, ".old-"}, context.temp_allocator)
	if !strings.has_prefix(path, prefix) do return false
	return release_version_ok(path[len(prefix):])
}
