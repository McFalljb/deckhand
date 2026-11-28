package core

// Install agy… (agy_install.odin) against fixtures only: a fake release folder (file: URLs: a
// manifest, a tarball made here), a temp folder in place of ~/.local/bin. Nothing is downloaded
// from Google and nothing here runs agy (the fixture "agy" is a shell script, never started).
// Every refusal leaves nothing at the install path (or the old agy as it was) and no private
// folder behind. The real codesign refuses the unsigned, ad-hoc and Apple-signed fixtures; the
// success path stands in for Google's signature (Agy_Job.sign), and the parsers of codesign's and
// spctl's answers are checked on their real shapes.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import jg "../jsonguard"

@(private = "file")
TP :: Agy_Platform{"darwin_arm64", "darwin-arm", "cli_mac_arm64.tar.gz"}
@(private = "file")
SHA_ZERO :: "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
@(private = "file")
GOOD_URL :: AGY_DOWNLOAD_PREFIX + "1.5.18-6386224290725888/darwin-arm/cli_mac_arm64.tar.gz"
@(private = "file")
FAKE_AGY :: "#!/bin/sh\necho 'fixture agy (tests): never run' >&2\nexit 1\n"

@(private = "file")
ai_dir :: proc(tag: string) -> string {
	d := fmt.tprintf("%s/deckhand-ai-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	return fs_real(d)
}

@(private = "file")
ai_write :: proc(path, text: string, mode := 0o644) {
	os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	_ = os.write_entire_file(path, transmute([]u8)text)
	os.change_mode(path, os.perm_number(mode))
}

@(private = "file")
ai_read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : "<none>"
}

// A fixture release under root/rel: the tarball made from the folder src's names (tar -C src),
// and a manifest naming it with its real SHA-512 (or sha). The job installs into root/bin.
@(private = "file")
ai_release :: proc(root, src: string, names: []string, version := "1.5.18", sha := "", url := "", absolute := false) -> Agy_Job {
	rel := upath(root, "rel")
	sub := fmt.tprintf("antigravity-cli/%s-123/%s", version, TP.folder)
	tgz := upath(rel, sub, TP.file)
	os.make_directory_all(upath(rel, sub))
	os.make_directory_all(upath(rel, "manifests"))
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "/usr/bin/env", "COPYFILE_DISABLE=1", "/usr/bin/tar", "--no-mac-metadata", "--no-xattrs", "-czf", tgz)
	if absolute do append(&args, "-P")
	else do append(&args, "-C", src)
	for n in names do append(&args, absolute ? upath(src, n) : n)
	_, st := run_group(args[:], 60 * time.Second)
	assert(st == .Ok, "tar made the fixture")
	sum := sha
	if sum == "" do sum, _ = agy_file_sha512(tgz)
	u := url != "" ? url : fmt.tprintf("file://%s/%s/%s", rel, sub, TP.file)
	ai_write(upath(rel, "manifests", TP.name + ".json"), fmt.tprintf(`{{"version":"%s","url":"%s","sha512":"%s"}}`, version, u, sum))
	return Agy_Job {
		manifest_url = fmt.tprintf("file://%s/manifests/%s.json", rel, TP.name),
		prefix = fmt.tprintf("file://%s/antigravity-cli/", rel),
		dir = upath(root, "bin"),
		test = true,
		ua = "Deckhand/test",
		platform = TP,
		sign = proc(bin: string) -> string {return ""}, // stands in for Google's signature
	}
}

// The fixture's one member: the fake agy as `antigravity`.
@(private = "file")
ai_src :: proc(root: string) -> string {
	src := upath(root, "src")
	ai_write(upath(src, AGY_MEMBER), FAKE_AGY, 0o755)
	return src
}

// Nothing of a run is left: no private folder in bin/.
@(private = "file")
ai_no_temp :: proc(t: ^testing.T, dir: string, loc := #caller_location) {
	d := posix.opendir(strings.clone_to_cstring(dir, context.temp_allocator))
	if d == nil do return
	defer posix.closedir(d)
	for {
		e := posix.readdir(d)
		if e == nil do break
		name := string(cstring(raw_data(e.d_name[:])))
		testing.expectf(t, !strings.has_prefix(name, AGY_TEMP_PREFIX), "a private folder is left: %s", name, loc = loc)
	}
}

// A refused run: its reason contains want, nothing is at bin/agy, no private folder.
@(private = "file")
ai_refused :: proc(t: ^testing.T, j: Agy_Job, want: string, loc := #caller_location) {
	v, err := agy_install_run(j)
	testing.expectf(t, v == "" && strings.contains(err, want), "refused with %q, got (%q, %q)", want, v, err, loc = loc)
	testing.expectf(t, path_kind_l_test(upath(j.dir, "agy")) == .Missing, "nothing at the install path", loc = loc)
	ai_no_temp(t, j.dir, loc)
}

@(private = "file")
path_kind_l_test :: proc(p: string) -> Path_Kind {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(p, context.temp_allocator), &st) != .OK do return .Missing
	return posix.S_ISREG(st.st_mode) ? .File : .Other
}

// ---- the manifest, read strictly ----

@(test)
agy_manifest_strict :: proc(t: ^testing.T) {
	m :: proc(version, url, sha: string) -> string {return fmt.tprintf(`{{"version":"%s","url":"%s","sha512":"%s"}}`, version, url, sha)}
	upper := strings.concatenate({"ABCDEF01", strings.to_upper(SHA_ZERO[:120], context.temp_allocator)}, context.temp_allocator)
	r, why := agy_manifest_parse(m("1.5.18", GOOD_URL, upper), TP, AGY_DOWNLOAD_PREFIX)
	testing.expectf(t, why == "" && r.version == "1.5.18" && r.url == GOOD_URL && r.sha512 == strings.to_lower(upper, context.temp_allocator), "the live shape: %v %q", r, why)
	// extra members are ignored, as t3code's schema does
	_, why = agy_manifest_parse(`{"version":"1.5.18","url":"` + GOOD_URL + `","sha512":"` + SHA_ZERO + `","notes":"x"}`, TP, AGY_DOWNLOAD_PREFIX)
	testing.expect_value(t, why, "")
	bad :: proc(t: ^testing.T, body, want: string, loc := #caller_location) {
		r, why := agy_manifest_parse(body, TP, AGY_DOWNLOAD_PREFIX)
		testing.expectf(t, strings.contains(why, want) && r.url == "", "%q: refused with %q, got %q", body, want, why, loc = loc)
	}
	// not JSON, not an object, a field missing or not a string
	bad(t, "", "not one Deckhand reads")
	bad(t, "{", "not one Deckhand reads")
	bad(t, `["1.5.18"]`, "not one Deckhand reads")
	bad(t, `{"version":"1.5.18","url":"` + GOOD_URL + `"}`, "not one Deckhand reads")
	bad(t, `{"version":1.5,"url":"` + GOOD_URL + `","sha512":"` + SHA_ZERO + `"}`, "not one Deckhand reads")
	// the version: N.N.N only, and at least AGY_MIN_VERSION
	for v in ([]string{"1.5", "v1.5.18", "1.5.18-beta", "1.5.18 ", "1..18", "1.5.x", "1.5.1234567890", "../1.5.18"}) do bad(t, m(v, GOOD_URL, SHA_ZERO), "version Deckhand does not read")
	bad(t, m("1.5.0", AGY_DOWNLOAD_PREFIX + "1.5.0-1/darwin-arm/cli_mac_arm64.tar.gz", SHA_ZERO), "older than 1.5.1")
	// the SHA-512: 128 hex
	bad(t, m("1.5.18", GOOD_URL, SHA_ZERO[:127]), "no SHA-512")
	bad(t, m("1.5.18", GOOD_URL, strings.concatenate({SHA_ZERO, "0"}, context.temp_allocator)), "no SHA-512")
	bad(t, m("1.5.18", GOOD_URL, strings.concatenate({SHA_ZERO[:127], "g"}, context.temp_allocator)), "no SHA-512")
	// the URL: exactly Google's folder for this Mac and this version
	elsewhere := "points somewhere other than Google's"
	for u in ([]string {
		"http://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-6386224290725888/darwin-arm/cli_mac_arm64.tar.gz", // http
		"https://storage.googleapis.com.evil.example/antigravity-public/antigravity-cli/1.5.18-6386224290725888/darwin-arm/cli_mac_arm64.tar.gz", // another host
		"https://evil.example/antigravity-public/antigravity-cli/1.5.18-6386224290725888/darwin-arm/cli_mac_arm64.tar.gz",
		"https://user@storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-6386224290725888/darwin-arm/cli_mac_arm64.tar.gz",
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-6386224290725888/darwin-x64/cli_mac_x64.tar.gz", // the other Mac's
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-6386224290725888/linux-arm/cli_linux_arm64.tar.gz", // Linux's
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-6386224290725888/darwin-arm/cli_mac_x64.tar.gz", // the wrong file
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.17-6386224290725888/darwin-arm/cli_mac_arm64.tar.gz", // another version
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-/darwin-arm/cli_mac_arm64.tar.gz", // no build number
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-12a/darwin-arm/cli_mac_arm64.tar.gz",
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-1/../darwin-arm/cli_mac_arm64.tar.gz", // traversal
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-1/x/../darwin-arm/cli_mac_arm64.tar.gz",
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-1/darwin-arm/../darwin-arm/cli_mac_arm64.tar.gz",
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-1/darwin-arm/cli_mac_arm64.tar.gz?x=1", // a query
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-1/darwin-arm/cli_mac_arm64.tar.gz#x",
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-1/darwin-arm/cli_mac_arm64.tar.gz/",
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-1//darwin-arm/cli_mac_arm64.tar.gz",
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-1/darwin-arm/cli_mac_arm64.tar.gz\n",
		"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.18-123456789012345678901234567890123/darwin-arm/cli_mac_arm64.tar.gz", // 33 digits
		"file:///etc/antigravity-cli/1.5.18-1/darwin-arm/cli_mac_arm64.tar.gz",
	}) {
		body := strings.concatenate({`{"version":"1.5.18","url":`, json_str(u), `,"sha512":"`, SHA_ZERO, `"}`}, context.temp_allocator)
		bad(t, body, elsewhere)
	}
	// too big
	bad(t, strings.concatenate({m("1.5.18", GOOD_URL, SHA_ZERO), strings.repeat(" ", AGY_MANIFEST_MAX, context.temp_allocator)}, context.temp_allocator), "too big")
	// another platform's check is its own
	testing.expect(t, agy_url_ok(AGY_DOWNLOAD_PREFIX + "1.5.18-1/darwin-x64/cli_mac_x64.tar.gz", "1.5.18", {"darwin_amd64", "darwin-x64", "cli_mac_x64.tar.gz"}, AGY_DOWNLOAD_PREFIX))
	testing.expect(t, !agy_url_ok(GOOD_URL, "1.5.18", {}, AGY_DOWNLOAD_PREFIX), "no platform: nothing passes")
}

@(private = "file")
json_str :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	json_quote(&b, s)
	return strings.to_string(b)
}

// ---- codesign's and spctl's answers (their real shapes: agy 1.5.18's) ----

@(test)
agy_signature_answers :: proc(t: ^testing.T) {
	google := "Executable=/x/agy\nIdentifier=cli\nFormat=Mach-O thin (arm64)\nAuthority=Developer ID Application: Google LLC (EQHXZ8M8AV)\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\nTeamIdentifier=EQHXZ8M8AV\n"
	testing.expect_value(t, agy_codesign_details_check(google), "")
	other := "Authority=Developer ID Application: Someone Else (ABCDE12345)\nAuthority=Developer ID Certification Authority\nTeamIdentifier=ABCDE12345\n"
	testing.expect(t, strings.contains(agy_codesign_details_check(other), "Someone Else"), "another team")
	mixed := "Authority=Developer ID Application: Google LLC (EQHXZ8M8AV)\nTeamIdentifier=ABCDE12345\n"
	testing.expect(t, agy_codesign_details_check(mixed) != "", "the team must be Google's too")
	adhoc := "Executable=/x/agy\nSignature=adhoc\nTeamIdentifier=not set\n"
	testing.expect(t, strings.contains(agy_codesign_details_check(adhoc), "nobody"), "ad-hoc")
	testing.expect(t, agy_codesign_details_check("") != "", "nothing")
	ok := "/x/agy: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Google LLC (EQHXZ8M8AV)\n"
	testing.expect_value(t, agy_spctl_check(ok), "")
	not_notarized := "/x/agy: accepted\nsource=Developer ID\norigin=Developer ID Application: Google LLC (EQHXZ8M8AV)\n"
	testing.expect(t, strings.contains(agy_spctl_check(not_notarized), "notarized"), "Developer ID but not notarized")
	rejected := "/x/agy: rejected\nsource=Notarized Developer ID\n"
	testing.expect(t, agy_spctl_check(rejected) != "", "rejected")
	testing.expect(t, agy_spctl_check("/x/agy: rejected (the code is valid but does not seem to be an app)\n") != "", "exec's answer")
	testing.expect(t, agy_spctl_check("") != "", "no answer")
}

// The real checks refuse what is not Google's: unsigned, ad-hoc signed, signed by Apple.
@(test)
agy_real_signature_refuses :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin {
		// no codesign or spctl: the check refuses whatever it is given
		testing.expect_value(t, agy_sign_check("/bin/true"), "Install agy is for macOS only")
		return
	}
	root := ai_dir("sig")
	defer os.remove_all(root)
	script := upath(root, "script")
	ai_write(script, FAKE_AGY, 0o755)
	testing.expect(t, strings.contains(agy_sign_check(script), "not signed with Google's Developer ID"), "unsigned")
	apple := upath(root, "apple")
	_, st := run_group({"/bin/cp", "/usr/bin/true", apple}, 30 * time.Second)
	testing.expect(t, st == .Ok)
	testing.expect(t, strings.contains(agy_sign_check(apple), "not signed with Google's Developer ID"), "Apple's own signature is not Google's")
	adhoc := upath(root, "adhoc")
	run_group({"/bin/cp", "/usr/bin/true", adhoc}, 30 * time.Second)
	_, cst := run_group({"/usr/bin/codesign", "-s", "-", "-f", adhoc}, 60 * time.Second)
	testing.expect(t, cst == .Ok, "ad-hoc signed")
	testing.expect(t, strings.contains(agy_sign_check(adhoc), "not signed with Google's Developer ID"), "ad-hoc")
	// and a whole run with the real checks: refused, nothing installed
	j := ai_release(root, ai_src(root), {AGY_MEMBER})
	j.sign = nil
	ai_refused(t, j, "not signed with Google's Developer ID")
}

// ---- whole runs ----

@(test)
agy_install_success :: proc(t: ^testing.T) {
	root := ai_dir("ok")
	defer os.remove_all(root)
	j := ai_release(root, ai_src(root), {AGY_MEMBER})
	v, err := agy_install_run(j)
	testing.expectf(t, v == "1.5.18" && err == "", "installed: %q %q", v, err)
	bin := upath(j.dir, "agy")
	testing.expect_value(t, ai_read(bin), FAKE_AGY)
	st: posix.stat_t
	posix.lstat(strings.clone_to_cstring(bin, context.temp_allocator), &st)
	_, bs := path_stat(bin)
	testing.expectf(t, posix.S_ISREG(st.st_mode) && bs.mode & 0o777 == 0o755 && st.st_nlink == 1, "a regular 0755 file, its own: %o %d", bs.mode, st.st_nlink)
	ai_no_temp(t, j.dir)
	// agy-seen.json as the extension writes it, and agy_detect reads it back
	data := upath(root, "data", "antigravity")
	testing.expect_value(t, agy_seen_write(data, bin, v), "")
	seen := ai_read(upath(data, "agy-seen.json"))
	o, _ := jg.parse_string(seen, .JSON, true, context.temp_allocator)
	obj := o.(json.Object)
	_, ds := path_stat(bin)
	testing.expectf(t, obj["path"].(json.String) == bin && obj["version"].(json.String) == "1.5.18" && i64(obj["size"].(json.Integer)) == ds.size && i64(obj["mtime"].(json.Integer)) == ds.mtime / 1_000_000_000 && len(obj) == 4, "agy-seen.json: %s", seen)
	_, fs := path_stat(upath(data, "agy-seen.json"))
	testing.expect_value(t, fs.mode & 0o777, 0o600)
	found, version := agy_detect(data, j.dir)
	testing.expect_value(t, found, bin)
	testing.expect_value(t, version, "1.5.18")
	// a second install refuses: something is there now (never overwritten)
	before := ai_read(bin)
	_, err = agy_install_run(j)
	testing.expectf(t, strings.contains(err, "appeared"), "a second install: %q", err)
	testing.expect_value(t, ai_read(bin), before)
	ai_no_temp(t, j.dir)
}

@(test)
agy_install_refusals :: proc(t: ^testing.T) {
	root := ai_dir("refuse")
	defer os.remove_all(root)
	src := ai_src(root)
	// the SHA-512 does not match
	ai_refused(t, ai_release(upath(root, "sha"), src, {AGY_MEMBER}, sha = SHA_ZERO), "does not match the SHA-512")
	// a manifest that points elsewhere (another file: folder)
	ai_refused(t, ai_release(upath(root, "url"), src, {AGY_MEMBER}, url = fmt.tprintf("file://%s/elsewhere/1.5.18-1/darwin-arm/cli_mac_arm64.tar.gz", root)), "points somewhere other")
	// the manifest is too big (curl's cap)
	j := ai_release(upath(root, "big"), src, {AGY_MEMBER})
	ai_write(j.manifest_url[len("file://"):], strings.repeat("x", AGY_MANIFEST_MAX + 10, context.temp_allocator))
	ai_refused(t, j, "Google's release list")
	// no manifest at all
	j = ai_release(upath(root, "none"), src, {AGY_MEMBER})
	os.remove(j.manifest_url[len("file://"):])
	ai_refused(t, j, "Google's release list")
	// the tarball is missing
	j = ai_release(upath(root, "gone"), src, {AGY_MEMBER})
	os.remove_all(upath(root, "gone", "rel", "antigravity-cli"))
	ai_refused(t, j, "the download")
	// an extra member
	ai_write(upath(src, "extra"), "x")
	ai_refused(t, ai_release(upath(root, "extra"), src, {AGY_MEMBER, "extra"}), "not one agy program")
	// the wrong name
	ai_write(upath(src, "agy"), FAKE_AGY, 0o755)
	ai_refused(t, ai_release(upath(root, "name"), src, {"agy"}), "not one agy program")
	// a link named antigravity
	links := upath(root, "links")
	os.make_directory_all(links)
	posix.symlink("/etc/passwd", strings.clone_to_cstring(upath(links, AGY_MEMBER), context.temp_allocator))
	ai_refused(t, ai_release(upath(root, "link"), links, {AGY_MEMBER}), "not one agy program")
	// a folder named antigravity (with the program inside)
	dirs := upath(root, "dirs")
	ai_write(upath(dirs, AGY_MEMBER, "agy"), FAKE_AGY, 0o755)
	ai_refused(t, ai_release(upath(root, "dir"), dirs, {AGY_MEMBER}), "not one agy program")
	// an absolute name
	ai_refused(t, ai_release(upath(root, "abs"), src, {AGY_MEMBER}, absolute = true), "not one agy program")
	// a path below a folder (antigravity/../antigravity is not the member's name either)
	nested := upath(root, "nested")
	ai_write(upath(nested, "x", AGY_MEMBER), FAKE_AGY, 0o755)
	ai_refused(t, ai_release(upath(root, "nest"), nested, {"x/antigravity"}), "not one agy program")
	// not a tarball at all (its SHA-512 matches: the list is Google's, the file is not a tar)
	j = ai_release(upath(root, "junk"), src, {AGY_MEMBER})
	tgz := upath(root, "junk", "rel", "antigravity-cli", "1.5.18-123", TP.folder, TP.file)
	ai_write(tgz, "not a tarball")
	sum, _ := agy_file_sha512(tgz)
	ai_write(j.manifest_url[len("file://"):], fmt.tprintf(`{{"version":"1.5.18","url":"file://%s","sha512":"%s"}}`, tgz, sum))
	ai_refused(t, j, "cannot read the download")
	// the signature: a stand-in that refuses (the real ones: agy_real_signature_refuses)
	j = ai_release(upath(root, "sign"), src, {AGY_MEMBER})
	j.sign = proc(bin: string) -> string {return "agy is signed by \"Someone Else\", not Google's: nothing was installed"}
	ai_refused(t, j, "Someone Else")
	// unit tests never fetch over https, nor install into ~/.local
	j = ai_release(upath(root, "https"), src, {AGY_MEMBER})
	j.test = false
	ai_refused(t, j, "never download from Google")
	if home := account_home(); home != "" {
		j = ai_release(upath(root, "home"), src, {AGY_MEMBER})
		j.dir = upath(home, ".local", "bin")
		_, err := agy_install_run(j)
		testing.expect(t, strings.contains(err, "never install into ~/.local"), err)
	}
}

@(test)
agy_update_runs :: proc(t: ^testing.T) {
	root := ai_dir("update")
	defer os.remove_all(root)
	src := ai_src(root)
	old :: "#!/bin/sh\n# the old fixture agy (tests): never run\nexit 1\n"
	setup :: proc(root, src, name: string) -> Agy_Job {
		j := ai_release(upath(root, name), src, {AGY_MEMBER})
		ai_write(upath(j.dir, "agy"), old, 0o755)
		j.update, j.installed = true, "1.5.10"
		_, j.expect = path_stat(upath(j.dir, "agy"))
		return j
	}
	// replaced by rename: the new one in place, nothing left
	j := setup(root, src, "ok")
	v, err := agy_install_run(j)
	testing.expectf(t, v == "1.5.18" && err == "", "updated: %q %q", v, err)
	testing.expect_value(t, ai_read(upath(j.dir, "agy")), FAKE_AGY)
	ai_no_temp(t, j.dir)
	// not newer: refused before any download, the old one as it was
	j = setup(root, src, "same")
	j.installed = "1.5.18"
	_, err = agy_install_run(j)
	testing.expectf(t, strings.contains(err, "not newer than yours"), "not newer: %q", err)
	testing.expect_value(t, ai_read(upath(j.dir, "agy")), old)
	// changed since the click: refused, the changed one kept
	j = setup(root, src, "changed")
	ai_write(upath(j.dir, "agy"), "#!/bin/sh\n# someone else's, since\nexit 1\n", 0o755)
	_, err = agy_install_run(j)
	testing.expectf(t, strings.contains(err, "changed since you clicked"), "changed: %q", err)
	testing.expect_value(t, ai_read(upath(j.dir, "agy")), "#!/bin/sh\n# someone else's, since\nexit 1\n")
	ai_no_temp(t, j.dir)
	// a link now: refused, the link kept
	j = setup(root, src, "link")
	os.remove(upath(j.dir, "agy"))
	posix.symlink(strings.clone_to_cstring(upath(root, "src", AGY_MEMBER), context.temp_allocator), strings.clone_to_cstring(upath(j.dir, "agy"), context.temp_allocator))
	_, err = agy_install_run(j)
	testing.expectf(t, strings.contains(err, "no longer the agy Deckhand found"), "a link: %q", err)
	testing.expect_value(t, path_kind_l_test(upath(j.dir, "agy")), Path_Kind.Other)
	ai_no_temp(t, j.dir)
	// a failure mid-run keeps the old one
	j = setup(root, src, "fail")
	j.sign = proc(bin: string) -> string {return "not Google's"}
	_, err = agy_install_run(j)
	testing.expect_value(t, err, "not Google's")
	testing.expect_value(t, ai_read(upath(j.dir, "agy")), old)
	ai_no_temp(t, j.dir)
}

// A private folder an earlier run left is removed by the next run; others' files stay.
@(test)
agy_install_sweeps_leftovers :: proc(t: ^testing.T) {
	root := ai_dir("sweep")
	defer os.remove_all(root)
	j := ai_release(root, ai_src(root), {AGY_MEMBER})
	ai_write(upath(j.dir, AGY_TEMP_PREFIX + "abc123", "agy.tar.gz"), "left over")
	ai_write(upath(j.dir, "other-tool"), "#!/bin/sh\n", 0o755)
	_, err := agy_install_run(j)
	testing.expect_value(t, err, "")
	ai_no_temp(t, j.dir)
	testing.expect_value(t, ai_read(upath(j.dir, "other-tool")), "#!/bin/sh\n")
}

// ---- what the row offers, the confirmation, the command ----

@(test)
agy_offer_rules :: proc(t: ^testing.T) {
	root := ai_dir("offer")
	defer os.remove_all(root)
	saved := agy_test_dir
	defer agy_test_dir = saved
	row := 0
	for r, i in HARNESS_MANIFEST do if r.id == "antigravity" do row = i
	when ODIN_OS != .Darwin {
		// Linux: the installer is macOS-only (Google's signature, codesign, spctl): never offered,
		// whatever the checklist says, and the row has no button
		agy_test_dir = upath(root, "bin")
		for st in ([]Harness_Item_State{.Missing, .Ok, .Too_Old}) {
			o, note := agy_install_offer({row = row, state = st, version = "1.5.0", where_ = upath(agy_test_dir, "agy")})
			testing.expectf(t, o == .None && note == "", "%v: %v %q", st, o, note)
			button, _ := agy_settings_row({row = row, state = st, version = "1.5.0"})
			testing.expect_value(t, button, "")
		}
		return
	}
	agy_test_dir = ""
	o, _ := agy_install_offer({row = row, state = .Missing})
	testing.expect_value(t, o, Agy_Offer.None) // no folder (test mode without its fixture): nothing
	agy_test_dir = upath(root, "bin")
	target := upath(agy_test_dir, "agy")
	o, _ = agy_install_offer({row = row, state = .Missing})
	testing.expect_value(t, o, Agy_Offer.Install)
	o, _ = agy_install_offer({row = row, state = .Needs_Harness})
	testing.expect_value(t, o, Agy_Offer.None)
	// an agy at the target the checklist did not find (not on the tabs' PATH): never overwritten
	ai_write(target, "#!/bin/sh\n", 0o755)
	note: string
	o, note = agy_install_offer({row = row, state = .Missing})
	testing.expectf(t, o == .None && strings.contains(note, "not on your tabs' PATH"), "%v %q", o, note)
	// ours, older than recommended: Update; current or unknown: nothing
	o, _ = agy_install_offer({row = row, state = .Ok, version = "1.5.10", where_ = target})
	testing.expect_value(t, o, Agy_Offer.Update)
	o, _ = agy_install_offer({row = row, state = .Too_Old, version = "1.5.0", where_ = target})
	testing.expect_value(t, o, Agy_Offer.Update)
	o, _ = agy_install_offer({row = row, state = .Ok, version = "1.5.18", where_ = target})
	testing.expect_value(t, o, Agy_Offer.None)
	o, _ = agy_install_offer({row = row, state = .Ok, version = "", where_ = target})
	testing.expect_value(t, o, Agy_Offer.None)
	// elsewhere: someone else's to update
	o, note = agy_install_offer({row = row, state = .Ok, version = "1.5.10", where_ = "/opt/homebrew/bin/agy"})
	testing.expectf(t, o == .None && strings.contains(note, "the way you installed it"), "%v %q", o, note)
	// a link at the target (to someone else's agy) is not ours either
	os.remove(target)
	posix.symlink("/opt/homebrew/bin/agy", strings.clone_to_cstring(target, context.temp_allocator))
	o, _ = agy_install_offer({row = row, state = .Ok, version = "1.5.10", where_ = target})
	testing.expect_value(t, o, Agy_Offer.None)
}

@(test)
agy_confirmation_says_what :: proc(t: ^testing.T) {
	s := agy_confirm_text(.Install, "/Users/u/.local/bin/agy")
	for want in ([]string{AGY_MANIFEST_HOST, "storage.googleapis.com/antigravity-public/antigravity-cli/", "SHA-512", "Google LLC (EQHXZ8M8AV)", "notarized by Apple", "does not run agy"}) do testing.expectf(t, strings.contains(s, want), "the confirmation names %q: %s", want, s)
	testing.expect(t, strings.contains(agy_confirm_text(.Update, "/x/agy"), "replaces"))
}

// install_agy: the user's at this Mac, refused when nothing is offered, always asked first; the
// confirmed run installs from the fixture and the row says so.
@(test)
agy_install_command :: proc(t: ^testing.T) {
	root := ai_dir("cmd")
	defer os.remove_all(root)
	j := ai_release(root, ai_src(root), {AGY_MEMBER})
	saved_dir, saved_rel, saved_signed, saved_probe, saved_seen := agy_test_dir, agy_test_release, agy_test_signed, harness_facts_probe, agy_test_seen_root
	defer {
		agy_test_dir, agy_test_release, agy_test_signed, harness_facts_probe, agy_test_seen_root = saved_dir, saved_rel, saved_signed, saved_probe, saved_seen
		harness_checklist_refresh(bump = false)
		agy_inst = {}
	}
	harness_facts_probe = proc() -> Harness_Facts {
		f: Harness_Facts
		f.installed[.Pi] = true
		f.bin[.Pi] = "/u/.pi/agent/bin/pi"
		f.version[.Pi] = "99.0.0"
		return f
	}
	ui := Caller{kind = .UI}
	// no folder: refused, nothing asked
	agy_test_dir = ""
	r := run_command(Install_Agy{}, ui)
	testing.expectf(t, !r.ok && r.error != "needs_confirmation", "nothing to offer: %v", r)
	agy_test_dir = j.dir
	agy_test_release = fmt.tprintf("file://%s/rel/", root)
	agy_test_signed = true
	agy_test_seen_root = upath(root, "data", "antigravity")
	// a control caller may not send it
	r = run_command(Install_Agy{}, Caller{kind = .Control})
	testing.expect_value(t, r.error, "not allowed for this caller")
	// the user: asked first, with what it does
	r = run_command(Install_Agy{}, ui)
	testing.expectf(t, r.error == "needs_confirmation" && strings.contains(r.confirm_summary, "SHA-512") && r.confirm_token != "", "asked: %v", r)
	testing.expect_value(t, agy_inst.phase, Agy_Install_Phase.None)
	r = run_command(Install_Agy{confirm = r.confirm_token}, ui)
	testing.expectf(t, r.ok, "confirmed: %v", r)
	testing.expect_value(t, agy_inst.phase, Agy_Install_Phase.Running)
	it := harness_item("antigravity")
	b, d := agy_settings_row(it^)
	testing.expectf(t, b == "" && strings.has_prefix(d, "Installing agy: "), "running: %q %q", b, d)
	r = run_command(Install_Agy{}, ui)
	testing.expectf(t, !r.ok && strings.contains(r.error, "being installed"), "one at a time: %v", r)
	deadline := time.tick_add(time.tick_now(), 60 * time.Second)
	for agy_inst.phase == .Running && time.tick_diff(time.tick_now(), deadline) > 0 {
		inbox_drain()
		time.sleep(20 * time.Millisecond)
	}
	testing.expectf(t, agy_inst.phase == .Done && agy_inst.version == "1.5.18", "done: %v", agy_inst)
	testing.expect_value(t, ai_read(upath(j.dir, "agy")), FAKE_AGY)
	ai_no_temp(t, j.dir)
	testing.expect(t, strings.contains(ai_read(upath(agy_test_seen_root, "agy-seen.json")), `"version":"1.5.18"`), "agy-seen.json written")
	// now there: Install is not offered again (not on this test's PATH: the row says where it is)
	harness_checklist_refresh(bump = false)
	b, d = agy_settings_row(harness_item("antigravity")^)
	testing.expectf(t, b == "" && strings.contains(d, "not on your tabs' PATH"), "after: %q %q", b, d)
	// a failed run says why on the row, and offers it again
	os.remove(upath(j.dir, "agy"))
	agy_test_signed = false // the real check: the fixture is not Google's
	r = run_command(Install_Agy{}, ui)
	r = run_command(Install_Agy{confirm = r.confirm_token}, ui)
	for agy_inst.phase == .Running && time.tick_diff(time.tick_now(), deadline) > 0 {
		inbox_drain()
		time.sleep(20 * time.Millisecond)
	}
	testing.expect_value(t, agy_inst.phase, Agy_Install_Phase.Failed)
	harness_checklist_refresh(bump = false)
	b, d = agy_settings_row(harness_item("antigravity")^)
	testing.expectf(t, b == "Install agy…" && d == "Failed: agy is not signed with Google's Developer ID (EQHXZ8M8AV): nothing was installed", "failed: %q %q", b, d)
	testing.expect_value(t, path_kind_l_test(upath(j.dir, "agy")), Path_Kind.Missing)
}
