package main

// pi-desk's updater (update.odin, update_core.odin, src/updatesig): versions, the
// release JSON, signatures, when to check, where it may install, the unpacked bundle's
// safety, the saved choices and who may send the commands (`./build.sh test`). No
// network: the scene tests/scripts/update.sh plays the downloads from local files.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import sig "updatesig"

@(private = "file")
U_UI :: Caller{kind = .UI}

// `odin build` type-checks this file too: a release build (no PI_DESK_UPDATE_TEST) has no test
// key, so these tests see an empty one there (they only run with the define: ./build.sh test).
when !PI_DESK_UPDATE_TEST {
	@(private = "file")
	UPDATE_TEST_PUBLIC_KEY :: ""
}

// a temp folder of its own (absolute), removed by the caller
@(private = "file")
u_tmp :: proc(name: string) -> string {
	base := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if base == "" do base = "/tmp"
	d := fmt.aprintf("%s/pd-update-%s-%d", base, name, time.now()._nsec % 1_000_000_000, allocator = runtime.heap_allocator())
	os.remove_all(d)
	os.make_directory_all(d)
	r: [4096]u8
	if rp := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), &r[0]); rp != nil do return strings.clone(string(rp), runtime.heap_allocator())
	return d
}

@(private = "file")
u_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	release_free(&upd.release)
	for s in ([]^string{&upd.current, &upd.bundle, &upd.why_not, &upd.skipped, &upd.backup, &upd.backup_for, &upd.cdhash, &upd.staged, &upd.message, &upd.url, &upd.download}) {
		delete(s^)
		s^ = ""
	}
	upd = {}
}

@(private = "file")
test_seed :: proc() -> string {
	data, err := os.read_entire_file("tests/update/test-key.txt", context.temp_allocator)
	if err != nil do return ""
	return strings.trim_space(string(data))
}

@(test)
update_semver :: proc(t: ^testing.T) {
	v, ok := semver_parse("v1.2.3")
	testing.expect(t, ok && v == Semver{1, 2, 3, false})
	v, ok = semver_parse("0.10.0")
	testing.expect(t, ok && v.minor == 10)
	v, ok = semver_parse("1.2.3-beta.1")
	testing.expect(t, ok && v.pre, "a pre-release")
	v, ok = semver_parse("1.2.3+build.7")
	testing.expect(t, ok && !v.pre, "build metadata dropped")
	for bad in ([]string{"", "1.2", "1.2.3.4", "01.2.3", "1.2.x", "1..3", "v", "1.2.3-", "1.2.3+", "1234567890.0.0", " 1.2.3", "1.2.3 "}) {
		_, ok = semver_parse(bad)
		testing.expectf(t, !ok, "%q is not a version", bad)
	}
	a, _ := semver_parse("0.1.0")
	b, _ := semver_parse("0.1.1")
	c, _ := semver_parse("0.2.0")
	d, _ := semver_parse("1.0.0")
	pre, _ := semver_parse("0.1.1-rc.1")
	testing.expect(t, semver_less(a, b) && semver_less(b, c) && semver_less(c, d))
	testing.expect(t, !semver_less(b, a) && !semver_less(a, a))
	testing.expect(t, semver_less(pre, b), "a pre-release is below its release")
	testing.expect(t, semver_less(a, pre))
	n9, _ := semver_parse("0.9.0")
	n10, _ := semver_parse("0.10.0")
	testing.expect(t, semver_less(n9, n10), "numbers, not text")
}

@(test)
update_offer_rules :: proc(t: ^testing.T) {
	testing.expect(t, update_offer("0.1.1", "0.1.0", ""))
	testing.expect(t, !update_offer("0.1.0", "0.1.0", ""), "the same version")
	testing.expect(t, !update_offer("0.0.9", "0.1.0", ""), "no downgrade")
	testing.expect(t, !update_offer("0.1.1", "0.1.0", "0.1.1"), "skipped")
	testing.expect(t, update_offer("0.1.2", "0.1.0", "0.1.1"), "a newer one than the skipped")
	testing.expect(t, !update_offer("0.1.1-rc.1", "0.1.0", ""), "no pre-releases")
	testing.expect(t, !update_offer("0.1.1", "", ""), "unknown running version (a development build)")
	testing.expect(t, !update_offer("junk", "0.1.0", ""))
}

@(private = "file")
release_json :: proc(tag: string, extra := "", zip_size := 1000, assets := "") -> string {
	v := strings.trim_prefix(tag, "v")
	z := fmt.tprintf("deckhand-%s-macos-arm64.zip", v)
	a := assets
	if a == "" do a = fmt.tprintf(`[{{"name":"%s","size":%d,"browser_download_url":"https://evil.example/x.zip"}},{{"name":"%s.sig","size":89}},{{"name":"%s.sha256","size":100}}]`, z, zip_size, z, z)
	return fmt.tprintf(`{{"tag_name":"%s","draft":false,"prerelease":false,"html_url":"https://evil.example/notes","body":"notes"%s,"assets":%s}}`, tag, extra, a)
}

@(test)
update_release_parse :: proc(t: ^testing.T) {
	r, err := release_parse(release_json("v0.1.1"), context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, r.version, "0.1.1")
	testing.expect_value(t, r.tag, "v0.1.1")
	testing.expect_value(t, r.zip_size, i64(1000))
	testing.expect(t, r.has_sig && r.has_sha)
	testing.expect_value(t, r.notes_url, "https://github.com/McFalljb/deckhand/releases/tag/v0.1.1") // never the JSON's html_url

	_, err = release_parse(release_json("v0.1.1", `,"draft":true`), context.temp_allocator)
	testing.expect(t, err != "", "a draft (the later key wins in the parser? either way refused)")
	_, err = release_parse(`{"tag_name":"v0.1.1","draft":true,"assets":[]}`, context.temp_allocator)
	testing.expect_value(t, err, "the latest release is a draft")
	_, err = release_parse(`{"tag_name":"v0.1.1","prerelease":true,"assets":[]}`, context.temp_allocator)
	testing.expect_value(t, err, "the latest release is a pre-release")
	for tag in ([]string{"v0.1", "0.1.1", "v0.1.1-rc.1", "v0.1.1+x", "v01.1.1", "release-1"}) {
		_, err = release_parse(release_json(tag), context.temp_allocator)
		testing.expectf(t, err != "", "tag %q refused", tag)
	}
	_, err = release_parse(release_json("v0.1.1", assets = `[]`), context.temp_allocator)
	testing.expect_value(t, err, "the release has no macOS arm64 zip")
	_, err = release_parse(release_json("v0.1.1", assets = `[{"name":"deckhand-0.1.1-macos-x64.zip","size":5}]`), context.temp_allocator)
	testing.expect_value(t, err, "the release has no macOS arm64 zip")
	// a pi-desk-named zip (0.1.x's) is not a Deckhand release's
	_, err = release_parse(release_json("v0.1.1", assets = `[{"name":"pi-desk-0.1.1-macos-arm64.zip","size":5},{"name":"pi-desk-0.1.1-macos-arm64.zip.sig","size":5}]`), context.temp_allocator)
	testing.expect_value(t, err, "the release has no macOS arm64 zip")
	_, err = release_parse(release_json("v0.1.1", zip_size = (1 << 30) + 1), context.temp_allocator)
	testing.expect_value(t, err, "the release's zip is over 1 GB")
	_, err = release_parse(release_json("v0.1.1", zip_size = 0), context.temp_allocator)
	testing.expect_value(t, err, "the release's zip has no size")
	r, err = release_parse(release_json("v0.1.1", assets = `[{"name":"deckhand-0.1.1-macos-arm64.zip","size":7}]`), context.temp_allocator)
	testing.expect(t, err == "" && !r.has_sig && !r.has_sha, "no .sig: offered, not installable")
	for bad in ([]string{"", "[]", "null", "{", `"x"`, `{"assets":[]}`}) {
		_, err = release_parse(bad, context.temp_allocator)
		testing.expectf(t, err != "", "%q refused", bad)
	}
	huge := strings.repeat("x", UPDATE_JSON_MAX, context.temp_allocator)
	_, err = release_parse(release_json("v0.1.1", fmt.tprintf(`,"body2":"%s"`, huge)), context.temp_allocator)
	testing.expect_value(t, err, "the release answer is too big")
	long_tag := strings.concatenate({"v1.2.3", strings.repeat("0", 40, context.temp_allocator)}, context.temp_allocator)
	_, err = release_parse(release_json(long_tag), context.temp_allocator)
	testing.expect(t, err != "")
}

@(test)
update_sha256_file :: proc(t: ^testing.T) {
	h := strings.repeat("ab", 32, context.temp_allocator)
	got, ok := sha256_file_parse(fmt.tprintf("%s  deckhand-0.1.1-macos-arm64.zip\n", h), "deckhand-0.1.1-macos-arm64.zip")
	testing.expect(t, ok && got == h)
	got, ok = sha256_file_parse(fmt.tprintf("%s  other.zip\n", h), "deckhand-0.1.1-macos-arm64.zip")
	testing.expect(t, !ok, "another file's")
	_, ok = sha256_file_parse("abc  deckhand-0.1.1-macos-arm64.zip", "deckhand-0.1.1-macos-arm64.zip")
	testing.expect(t, !ok, "short hash")
	_, ok = sha256_file_parse(fmt.tprintf("%sZZ  x", strings.repeat("a", 62, context.temp_allocator)), "x")
	testing.expect(t, !ok, "not hex")
}

@(test)
update_signatures :: proc(t: ^testing.T) {
	seed := test_seed()
	testing.expect(t, seed != "", "tests/update/test-key.txt")
	pub, ok := sig.public_of(seed)
	testing.expect(t, ok)
	testing.expect_value(t, pub, UPDATE_TEST_PUBLIC_KEY)
	m := sig.manifest("0.1.1", "deckhand-0.1.1-macos-arm64.zip", 1234, strings.repeat("AB", 32, context.temp_allocator), strings.repeat("cd", 20, context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(m, "sha256 abab"), "hex lower-cased")
	s, sok := sig.sign(seed, transmute([]byte)m)
	testing.expect(t, sok)
	testing.expect(t, sig.verify(UPDATE_TEST_PUBLIC_KEY, transmute([]byte)m, s), "good")
	testing.expect(t, sig.verify(UPDATE_TEST_PUBLIC_KEY, transmute([]byte)m, fmt.tprintf("  %s\n", s)), "whitespace around it")
	// another version, size or hash: the same signature fails
	for other in ([]string{
		sig.manifest("0.1.2", "deckhand-0.1.1-macos-arm64.zip", 1234, strings.repeat("ab", 32, context.temp_allocator), strings.repeat("cd", 20, context.temp_allocator), context.temp_allocator),
		sig.manifest("0.1.1", "deckhand-0.1.1-macos-arm64.zip", 1235, strings.repeat("ab", 32, context.temp_allocator), strings.repeat("cd", 20, context.temp_allocator), context.temp_allocator),
		sig.manifest("0.1.1", "deckhand-0.1.1-macos-arm64.zip", 1234, strings.repeat("ab", 32, context.temp_allocator), strings.repeat("ce", 20, context.temp_allocator), context.temp_allocator),
		sig.manifest("0.1.1", "deckhand-0.1.1-macos-arm64.zip", 1234, strings.repeat("ac", 32, context.temp_allocator), strings.repeat("cd", 20, context.temp_allocator), context.temp_allocator),
	}) {
		testing.expect(t, !sig.verify(UPDATE_TEST_PUBLIC_KEY, transmute([]byte)other, s), "bound to version, size, hash, cdhash")
	}
	testing.expect(t, !sig.verify(UPDATE_TEST_PUBLIC_KEY, transmute([]byte)m, ""), "missing")
	testing.expect(t, !sig.verify(UPDATE_TEST_PUBLIC_KEY, transmute([]byte)m, "not base64!"), "malformed")
	testing.expect(t, !sig.verify(UPDATE_TEST_PUBLIC_KEY, transmute([]byte)m, s[:len(s) - 4]), "short")
	flipped := transmute([]byte)strings.clone(s, context.temp_allocator)
	flipped[3] = flipped[3] == 'A' ? 'B' : 'A'
	testing.expect(t, !sig.verify(UPDATE_TEST_PUBLIC_KEY, transmute([]byte)m, string(flipped)), "bad")
	_, other_pub, gok := sig.generate()
	testing.expect(t, gok)
	testing.expect(t, !sig.verify(other_pub, transmute([]byte)m, s), "wrong key")
	testing.expect(t, !sig.verify(UPDATE_PUBLIC_KEY, transmute([]byte)m, s), "the release key never takes the test key's signatures")
	testing.expect(t, !sig.verify("PLACEHOLDER-x", transmute([]byte)m, s), "a placeholder never verifies")
	testing.expect(t, sig.is_placeholder(UPDATE_PUBLIC_KEY) || UPDATE_PUBLIC_KEY != UPDATE_TEST_PUBLIC_KEY, "the release key is never the test key")
	_, bad := sig.sign("short", transmute([]byte)m)
	testing.expect(t, !bad, "a seed must be 32 bytes")
}

@(test)
update_due_rules :: proc(t: ^testing.T) {
	now := i64(1_800_000_000)
	testing.expect(t, update_due(now, 0, 0, true), "never checked")
	testing.expect(t, !update_due(now, 0, 0, false), "checks off")
	testing.expect(t, !update_due(now, now - 3600, now - 3600, true), "checked an hour ago")
	testing.expect(t, update_due(now, now - UPDATE_INTERVAL, now - UPDATE_INTERVAL, true), "a day ago")
	testing.expect(t, !update_due(now, now - 2 * UPDATE_INTERVAL, now - 60, true), "a failed try a minute ago: wait")
	testing.expect(t, update_due(now, now - 2 * UPDATE_INTERVAL, now - UPDATE_RETRY, true), "an hour after a failed try")
	testing.expect(t, update_due(now, now + 1000, now + 1000, true), "the clock went back")
}

@(private = "file")
u_writable_all :: proc(path: string) -> bool {return true}
@(private = "file")
u_writable_none :: proc(path: string) -> bool {return false}
@(private = "file")
u_writable_parent_only :: proc(path: string) -> bool {return !strings.has_suffix(path, ".app")}

@(test)
update_install_decision :: proc(t: ^testing.T) {
	b, why := install_decision("/Applications/Deckhand.app/Contents/MacOS/Deckhand", u_writable_all)
	testing.expect_value(t, why, "")
	testing.expect_value(t, b, "/Applications/Deckhand.app")
	b, why = install_decision("/Users/me/Apps/My pi.app/Contents/MacOS/Deckhand", u_writable_all)
	testing.expect(t, why == "" && b == "/Users/me/Apps/My pi.app", "renamed and elsewhere is fine")
	_, why = install_decision("/private/var/folders/x/T/AppTranslocation/ABC/d/Deckhand.app/Contents/MacOS/Deckhand", u_writable_all)
	testing.expect(t, strings.contains(why, "App Translocation"), why)
	_, why = install_decision("/usr/local/bin/pi-desk", u_writable_all)
	testing.expect_value(t, why, "Deckhand is not running from an app bundle")
	_, why = install_decision("/x/Deckhand.app/Contents/Resources/Deckhand", u_writable_all)
	testing.expect_value(t, why, "Deckhand is not running from an app bundle")
	_, why = install_decision("/Applications/Deckhand.app/Contents/MacOS/Deckhand", u_writable_none)
	testing.expect(t, strings.contains(why, "cannot write to /Applications"), why)
	_, why = install_decision("/Applications/Deckhand.app/Contents/MacOS/Deckhand", u_writable_parent_only)
	testing.expect(t, strings.contains(why, "cannot write to /Applications/Deckhand.app"), why)
	_, why = install_decision("/Volumes/pi-desk/Deckhand.app/Contents/MacOS/Deckhand", u_writable_none)
	testing.expect(t, strings.contains(why, "disk image"), why)
	// a development build: build/Deckhand.app beside build.sh
	repo := u_tmp("repo")
	defer {os.remove_all(repo); delete(repo, runtime.heap_allocator())}
	os.make_directory_all(upath(repo, "build"))
	_ = os.write_entire_file(upath(repo, "build.sh"), transmute([]byte)string("#!/bin/sh\n"))
	_, why = install_decision(upath(repo, "build", "Deckhand.app", "Contents", "MacOS", "Deckhand"), u_writable_all)
	testing.expect(t, strings.contains(why, "development build"), why)
}

@(test)
update_links_and_names :: proc(t: ^testing.T) {
	// CEF's framework links, as they are
	testing.expect(t, link_inside("Contents/Frameworks/C.framework/Resources", "Versions/Current/Resources"))
	testing.expect(t, link_inside("Contents/Frameworks/C.framework/Versions/Current", "A"))
	testing.expect(t, link_inside("Contents/a/b/l", "../../MacOS/Deckhand"))
	testing.expect(t, !link_inside("Contents/l", "../../x"), "above the bundle")
	testing.expect(t, !link_inside("Contents/l", ".."), "the bundle itself")
	testing.expect(t, !link_inside("l", "../Deckhand.app/x"), "out and back in is still out")
	testing.expect(t, !link_inside("Contents/l", "/etc/passwd"), "absolute")
	testing.expect(t, !link_inside("Contents/l", ""), "empty")
	testing.expect(t, link_inside("Contents/a/l", "b/../../../x"), "down to the bundle's top, still inside")
	testing.expect(t, !link_inside("Contents/a/l", "b/../../../../Deckhand.app/x"), "climbs out midway and back")

	testing.expect_value(t, zip_names_check("Deckhand.app/\nDeckhand.app/Contents/\nDeckhand.app/Contents/._MacOS\n"), "")
	testing.expect_value(t, zip_names_check("Deckhand.app/../../x\n"), "the zip has a path with ..")
	testing.expect_value(t, zip_names_check("/etc/x\n"), "the zip has an absolute path")
	testing.expect_value(t, zip_names_check("Deckhand.app/\nother.app/x\n"), "the zip holds more than Deckhand.app")
	testing.expect_value(t, zip_names_check("Deckhand.application/x\n"), "the zip holds more than Deckhand.app")
	// pi-desk's bundle name (0.1.x releases): not what a Deckhand release holds
	testing.expect_value(t, zip_names_check("pi-desk.app/\npi-desk.app/Contents/\n"), "the zip holds more than Deckhand.app")
	testing.expect_value(t, zip_names_check(""), "the zip is empty")
}

@(private = "file")
u_mkapp :: proc(root: string) -> string {
	app := upath(root, "Deckhand.app")
	os.make_directory_all(upath(app, "Contents", "MacOS"))
	os.make_directory_all(upath(app, "Contents", "Frameworks", "C.framework", "Versions", "A"))
	_ = os.write_entire_file(upath(app, "Contents", "MacOS", "Deckhand"), transmute([]byte)string("x"))
	os.symlink("A", upath(app, "Contents", "Frameworks", "C.framework", "Versions", "Current"))
	return app
}

@(test)
update_extract_check :: proc(t: ^testing.T) {
	root := u_tmp("x")
	defer {os.remove_all(root); delete(root, runtime.heap_allocator())}
	app := u_mkapp(root)
	testing.expect_value(t, extract_check(root), "")

	os.symlink("../../../../outside", upath(app, "Contents", "esc"))
	testing.expect(t, strings.contains(extract_check(root), "points outside"), "a link out")
	os.remove(upath(app, "Contents", "esc"))
	os.symlink("/etc", upath(app, "Contents", "abs"))
	testing.expect(t, strings.contains(extract_check(root), "points outside"), "an absolute link")
	os.remove(upath(app, "Contents", "abs"))
	testing.expect_value(t, extract_check(root), "")

	suid := upath(app, "Contents", "MacOS", "helper")
	_ = os.write_entire_file(suid, transmute([]byte)string("x"))
	posix.chmod(strings.clone_to_cstring(suid, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR, .ISUID})
	testing.expect(t, strings.contains(extract_check(root), "setuid"), "setuid")
	os.remove(suid)

	fifo := upath(app, "Contents", "pipe")
	posix.mkfifo(strings.clone_to_cstring(fifo, context.temp_allocator), {.IRUSR, .IWUSR})
	testing.expect(t, strings.contains(extract_check(root), "not a file, folder or link"), "a fifo")
	os.remove(fifo)

	os.make_directory(upath(root, "extra"))
	testing.expect_value(t, extract_check(root), "the zip does not hold exactly Deckhand.app")
	os.remove(upath(root, "extra"))

	// Deckhand.app itself a link to elsewhere
	root2 := u_tmp("x2")
	defer {os.remove_all(root2); delete(root2, runtime.heap_allocator())}
	os.symlink(app, upath(root2, "Deckhand.app"))
	testing.expect_value(t, extract_check(root2), "the app in the zip is not a folder")
}

// A minimal bundle with an Info.plist, signed ad hoc (codesign, PlistBuddy: local tools only).
@(private = "file")
u_bundle :: proc(root, id, version: string) -> string {
	app := u_mkapp(root)
	os.remove(upath(app, "Contents", "MacOS", "Deckhand"))
	run_group({"/bin/cp", "/usr/bin/true", upath(app, "Contents", "MacOS", "Deckhand")}, 10 * time.Second)
	os.remove_all(upath(app, "Contents", "Frameworks"))
	plist := fmt.tprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>%s</string>
<key>CFBundleExecutable</key><string>Deckhand</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>%s</string>
</dict></plist>
`, id, version)
	_ = os.write_entire_file(upath(app, "Contents", "Info.plist"), transmute([]byte)plist)
	run_group({"/usr/bin/codesign", "--force", "--sign", "-", app}, 60 * time.Second)
	return app
}

@(test)
update_bundle_check :: proc(t: ^testing.T) {
	root := u_tmp("bundle")
	defer {os.remove_all(root); delete(root, runtime.heap_allocator())}
	app := u_bundle(root, UPDATE_BUNDLE_ID, "0.1.1")
	cd := codesign_cdhash(app)
	testing.expect(t, sig.cdhash_valid(cd), cd)
	testing.expect_value(t, bundle_check(app, "0.1.1", cd), "")
	testing.expect(t, strings.contains(bundle_check(app, "0.1.2", cd), "version"), "not the tag's version")
	// a change after signing breaks codesign
	_ = os.write_entire_file(upath(app, "Contents", "Resources.txt"), transmute([]byte)string("x"))
	testing.expect_value(t, bundle_check(app, "0.1.1", cd), "the update's code signature does not verify, or it changed since it was checked")
	root2 := u_tmp("bundle2")
	defer {os.remove_all(root2); delete(root2, runtime.heap_allocator())}
	other := u_bundle(root2, "com.example.other", "0.1.1")
	testing.expect(t, strings.contains(bundle_check(other, "0.1.1", codesign_cdhash(other)), "not Deckhand"), "another bundle id")
}

@(test)
update_commands_are_the_users :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and upd outlive the test's allocator
	u_reset()
	defer u_reset()
	for c in ([]Command{Update_Check{}, Update_Skip{}, Update_Later{}, Update_Download{}, Update_Install{}, Set_Update_Check{on = false}}) {
		for k in ([]Caller_Kind{.Control, .Script, .Panel, .App}) {
			testing.expectf(t, !caller_may({kind = k}, c), "%v may not send %v", k, command_type(c))
		}
		testing.expectf(t, caller_may(U_UI, c), "the user sends %v", command_type(c))
	}
	for c in ([]Command{Update_Env{}, Update_Tick{}, Update_Checked{}, Update_Prepared{}}) {
		testing.expectf(t, !caller_may(U_UI, c) && !caller_may({kind = .Control}, c), "%v is internal", command_type(c))
	}
	// the JSON parser knows only the user's ones
	for name in ([]string{"update_env", "update_tick", "update_checked", "update_prepared"}) {
		_, perr := parse_command(fmt.tprintf(`{{"type":"%s"}}`, name), context.temp_allocator)
		testing.expectf(t, perr != "", "%s is never parsed", name)
	}
}

@(test)
update_offer_flow :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and upd outlive the test's allocator
	u_reset()
	defer u_reset()
	dir := u_tmp("flow")
	defer {os.remove_all(dir); delete(dir, runtime.heap_allocator())}
	old_root := home_root
	home_root = dir
	defer home_root = old_root
	run_command(Update_Env{version = "0.1.0", bundle = "/Applications/Deckhand.app"})
	testing.expect(t, upd.known && upd.current == "0.1.0")
	// a check's answer: offered
	run_command(Update_Checked{body = release_json("v0.1.1")})
	testing.expect(t, upd.offered && update_bar_shows())
	testing.expect(t, upd.last_ok > 0)
	sj := state_json()
	testing.expect(t, strings.contains(sj, `"update":{"checks":true,"current":"0.1.0","phase":"none","available":true,"latest":"0.1.1"`), sj)
	// Later hides; the same release again keeps it hidden; a newer one shows
	run_command(Update_Later{}, U_UI)
	testing.expect(t, !update_bar_shows())
	run_command(Update_Checked{body = release_json("v0.1.1")})
	testing.expect(t, !update_bar_shows(), "Later holds for the same version")
	run_command(Update_Checked{body = release_json("v0.1.2")})
	testing.expect(t, update_bar_shows(), "a newer one shows again")
	// Skip: saved, not offered again
	r := run_command(Update_Skip{}, U_UI)
	testing.expect(t, r.ok)
	testing.expect(t, !upd.offered && upd.skipped == "0.1.2")
	run_command(Update_Checked{body = release_json("v0.1.2")})
	testing.expect(t, !upd.offered, "skipped stays skipped")
	saved, _ := os.read_entire_file(upath(dir, "update.json"), context.temp_allocator)
	testing.expect(t, strings.contains(string(saved), `"skip":"0.1.2"`), string(saved))
	// a failed check: logged in state, nothing offered
	run_command(Update_Checked{err = "offline"})
	testing.expect_value(t, upd.message, "offline")
	// the setting: saved and loaded back
	run_command(Set_Update_Check{on = false}, U_UI)
	testing.expect(t, upd.checks_off)
	upd.checks_off = false
	delete(upd.skipped)
	upd.skipped = ""
	update_load()
	testing.expect(t, upd.checks_off && upd.skipped == "0.1.2", "update.json read back")
	info, _ := os.stat(upath(dir, "update.json"), context.temp_allocator)
	testing.expect(t, info.mode & {.Read_Group, .Read_Other, .Write_Group, .Write_Other} == {}, "0600")
	// a tick with checks off: nothing
	run_command(Update_Tick{})
	testing.expect(t, upd.phase == .None)
}

@(test)
update_download_refusals :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and upd outlive the test's allocator
	u_reset()
	defer u_reset()
	old_root := home_root
	home_root = ""
	defer home_root = old_root
	r := run_command(Update_Download{}, U_UI)
	testing.expect(t, !r.ok, "nothing offered")
	run_command(Update_Env{version = "0.1.0", why_not = "you cannot write to /Applications, where Deckhand.app is"})
	run_command(Update_Checked{body = release_json("v0.1.1")})
	r = run_command(Update_Download{}, U_UI)
	testing.expect(t, !r.ok && strings.contains(r.error, "cannot write"), r.error)
	msg, parts := update_bar_parts()
	testing.expect(t, strings.contains(msg, "cannot write"), msg)
	for p in parts do testing.expect(t, p != .Update, "no Update button where it cannot install")
	// an installable place, but this build's key is the placeholder (not test mode)
	run_command(Update_Env{version = "0.1.0", bundle = "/Applications/Deckhand.app"})
	upd.phase = .None
	if sig.is_placeholder(UPDATE_PUBLIC_KEY) {
		r = run_command(Update_Download{}, U_UI)
		testing.expect(t, !r.ok && strings.contains(r.error, "no update key"), r.error)
	}
	// no .sig on the release
	upd.test = true
	upd.phase = .None
	run_command(Update_Checked{body = release_json("v0.1.3", assets = `[{"name":"deckhand-0.1.3-macos-arm64.zip","size":7}]`)})
	r = run_command(Update_Download{}, U_UI)
	testing.expect(t, !r.ok && strings.contains(r.error, "no signature"), r.error)
	// install with nothing ready
	r = run_command(Update_Install{}, U_UI)
	testing.expect(t, !r.ok)
}

@(test)
update_swap_is_atomic :: proc(t: ^testing.T) {
	root := u_tmp("swap")
	defer {os.remove_all(root); delete(root, runtime.heap_allocator())}
	a, b := upath(root, ".deckhand-update-0.1.1.app"), upath(root, "Deckhand.app")
	os.make_directory_all(a)
	os.make_directory_all(b)
	_ = os.write_entire_file(upath(a, "v"), transmute([]byte)string("new"))
	_ = os.write_entire_file(upath(b, "v"), transmute([]byte)string("old"))
	testing.expect(t, swap_paths(a, b), "APFS swaps")
	got, _ := os.read_entire_file(upath(b, "v"), context.temp_allocator)
	testing.expect_value(t, string(got), "new")
	got, _ = os.read_entire_file(upath(a, "v"), context.temp_allocator)
	testing.expect_value(t, string(got), "old")
	testing.expect(t, !swap_paths(upath(root, "missing"), b), "nothing to swap with")
}

// ---- security review round 1 ----

@(test)
update_sig_file_format :: proc(t: ^testing.T) {
	CD :: "abababababababababababababababababababab"
	cd := CD
	text := sig.sig_file_make(cd, "QUJD", context.temp_allocator)
	c, b, ok := sig.sig_file_parse(text)
	testing.expect(t, ok && c == cd && b == "QUJD", text)
	for bad in ([]string{"", "QUJD\n", "pi-desk-update-sig v2\ncdhash xyz\nsignature QUJD\n", "pi-desk-update-sig v1\ncdhash " + CD + "\nsignature QUJD\n", "pi-desk-update-sig v2\nsignature QUJD\ncdhash " + CD + "\n", "pi-desk-update-sig v2\ncdhash " + CD + "\nsignature QUJD\nextra\n"}) {
		_, _, bok := sig.sig_file_parse(bad)
		testing.expectf(t, !bok, "%q refused", bad)
	}
}

// 1. A staged bundle changed after it was checked (re-signed: codesign still passes, the
// CDHash differs) is refused right before the rename; so is one that is a link.
@(test)
update_install_check_staged :: proc(t: ^testing.T) {
	root := u_tmp("stagecheck")
	defer {os.remove_all(root); delete(root, runtime.heap_allocator())}
	app := u_bundle(root, UPDATE_BUNDLE_ID, "0.1.1")
	signed := strings.clone(codesign_cdhash(app), context.temp_allocator)
	testing.expect_value(t, install_check(app, "0.1.1", signed), "")
	os.make_directory_all(upath(app, "Contents", "Resources"))
	_ = os.write_entire_file(upath(app, "Contents", "Resources", "extra.txt"), transmute([]byte)string("x"))
	run_group({"/usr/bin/codesign", "--force", "--sign", "-", app}, 60 * time.Second)
	testing.expect(t, strings.contains(install_check(app, "0.1.1", signed), "changed since it was checked"), install_check(app, "0.1.1", signed))
	testing.expect_value(t, install_check(app, "0.1.1", codesign_cdhash(app)), "") // re-sealed: only the signed CDHash tells
	testing.expect(t, install_check(app, "0.1.2", codesign_cdhash(app)) != "", "the version")
	testing.expect(t, install_check(app, "0.1.1", "") != "", "no signed cdhash")
	link := upath(root, "link.app")
	os.symlink(app, link)
	testing.expect(t, strings.contains(install_check(link, "0.1.1", codesign_cdhash(app)), "not a folder of yours"), "a link")
}

// 2. Test mode never installs into /Applications, however the path is spelled.
@(test)
update_under_applications :: proc(t: ^testing.T) {
	for p in ([]string{"/Applications/Deckhand.app", "//Applications/Deckhand.app", "/Applications/../Applications/Deckhand.app", "/System/Volumes/Data/Applications/Deckhand.app", "/applications/Deckhand.app", "/Applications"}) {
		testing.expectf(t, under_applications(p), "%q is under /Applications", p)
	}
	for p in ([]string{"/Users/me/Applications/Deckhand.app", "/tmp/Applications-x/Deckhand.app", "/ApplicationsX/Deckhand.app"}) {
		testing.expectf(t, !under_applications(p), "%q is not", p)
	}
	// a link to /Applications
	root := u_tmp("applink")
	defer {os.remove_all(root); delete(root, runtime.heap_allocator())}
	os.symlink("/Applications", upath(root, "apps"))
	testing.expect(t, under_applications(upath(root, "apps", "Deckhand.app")), "through a link")
	when PI_DESK_UPDATE_TEST {
		upd.test = true
		testing.expect_value(t, update_key(), UPDATE_TEST_PUBLIC_KEY)
		upd.test = false
		testing.expect_value(t, update_key(), UPDATE_PUBLIC_KEY)
	}
}

// 3. A link that is lexically inside but really resolves outside (through another link).
@(test)
update_extract_links_real :: proc(t: ^testing.T) {
	root := u_tmp("xreal")
	defer {os.remove_all(root); delete(root, runtime.heap_allocator())}
	app := u_mkapp(root)
	os.make_directory_all(upath(app, "Contents", "Resources"))
	os.symlink(".", upath(app, "Contents", "Resources", "a"))
	os.symlink("a/../../../x", upath(app, "Contents", "Resources", "b"))
	testing.expect(t, strings.contains(extract_check(root), "points outside"), extract_check(root))
}

// 4. remove_tree keeps going past a part it cannot remove, and never follows links.
@(test)
update_remove_tree :: proc(t: ^testing.T) {
	root := u_tmp("rm")
	defer {
		posix.chmod(strings.clone_to_cstring(upath(root, "t", "m", "locked"), context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
		os.remove_all(root)
		delete(root, runtime.heap_allocator())
	}
	outside := upath(root, "outside")
	os.make_directory_all(outside)
	_ = os.write_entire_file(upath(outside, "keep"), transmute([]byte)string("x"))
	tree := upath(root, "t")
	for d in ([]string{"a", "b", "m/locked", "z"}) do os.make_directory_all(upath(tree, d))
	for d in ([]string{"a", "b", "z"}) do _ = os.write_entire_file(upath(tree, d, "f"), transmute([]byte)string("x"))
	_ = os.write_entire_file(upath(tree, "m", "locked", "f"), transmute([]byte)string("x"))
	posix.chmod(strings.clone_to_cstring(upath(tree, "m", "locked"), context.temp_allocator), {.IRUSR, .IXUSR}) // its file cannot go
	os.symlink(outside, upath(tree, "link"))
	remove_tree(tree)
	testing.expect(t, os.exists(upath(outside, "keep")), "the link's target is untouched")
	for d in ([]string{"a", "b", "z", "link"}) do testing.expectf(t, !os.exists(upath(tree, d)), "%s removed past the error", d)
	testing.expect(t, os.exists(upath(tree, "m", "locked", "f")), "the locked part stays")
}

// 5. update.json's paths: only our own names, next to the bundle.
@(test)
update_saved_paths :: proc(t: ^testing.T) {
	b := "/Applications/Deckhand.app"
	testing.expect(t, staged_path_ok("/Applications/.deckhand-update-0.1.1.app", b))
	testing.expect(t, backup_path_ok("/Applications/Deckhand.app.old-0.1.0", b))
	for p in ([]string{"/Applications/.deckhand-update-0.1.1.app/..", "/Users/me/.deckhand-update-0.1.1.app", "/Applications/.deckhand-update-x.app", "/Applications/.deckhand-update-0.1.1.appx", "/Applications/../Users/.deckhand-update-0.1.1.app", "/Applications/.deckhand-update-.app", ""}) {
		testing.expectf(t, !staged_path_ok(p, b), "staged %q refused", p)
	}
	for p in ([]string{"/Applications/Deckhand.app.old-0.1.0/../../Users", "/Applications/Deckhand.app.old-", "/Applications/Deckhand.app.old-0.1.0x", "/Users/me/Deckhand.app.old-0.1.0", "/Applications/Deckhand.app", "/Applications/../Applications/Deckhand.app.old-0.1.0", ""}) {
		testing.expectf(t, !backup_path_ok(p, b), "backup %q refused", p)
	}
	testing.expect(t, !staged_path_ok("/Applications/.deckhand-update-0.1.1.app", ""), "no bundle: nothing is ours")
}

// 6. The old bundle stays until the new version has started a second time.
@(test)
update_backup_kept_until_second_start :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	u_reset()
	defer u_reset()
	dir := u_tmp("keep")
	defer {os.remove_all(dir); delete(dir, runtime.heap_allocator())}
	old_root := home_root
	home_root = dir
	defer home_root = old_root
	bundle := upath(dir, "Deckhand.app")
	backup := fmt.tprintf("%s.old-0.1.0", bundle)
	os.make_directory_all(bundle)
	os.make_directory_all(backup)
	update_set_backup_for_test(backup, "0.1.1")
	update_save()
	// first start of 0.1.1
	update_load()
	run_command(Update_Env{version = "0.1.1", bundle = bundle})
	testing.expect(t, os.exists(backup), "kept at the new version's first start")
	// second start
	u_reset()
	update_load()
	run_command(Update_Env{version = "0.1.1", bundle = bundle})
	testing.expect(t, !os.exists(backup), "removed at its second start")
}

// 7. Group- or world-writable files in the update are refused.
@(test)
update_extract_group_writable :: proc(t: ^testing.T) {
	root := u_tmp("gw")
	defer {os.remove_all(root); delete(root, runtime.heap_allocator())}
	app := u_mkapp(root)
	f := upath(app, "Contents", "MacOS", "Deckhand")
	posix.chmod(strings.clone_to_cstring(f, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR, .IWGRP})
	testing.expect(t, strings.contains(extract_check(root), "writable by others"), extract_check(root))
	posix.chmod(strings.clone_to_cstring(f, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	posix.chmod(strings.clone_to_cstring(upath(app, "Contents"), context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR, .IROTH, .IWOTH, .IXOTH})
	testing.expect(t, strings.contains(extract_check(root), "writable by others"), "a folder too")
}

// 8. A check while an update is ready keeps the ready one.
@(test)
update_check_keeps_ready :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	u_reset()
	defer u_reset()
	old_root := home_root
	home_root = ""
	defer home_root = old_root
	run_command(Update_Env{version = "0.1.0", bundle = "/x/Deckhand.app"})
	run_command(Update_Checked{body = release_json("v0.1.1")})
	upd.phase = .Ready
	update_set_staged_for_test("/x/.deckhand-update-0.1.1.app")
	run_command(Update_Checked{body = release_json("v0.1.2")})
	testing.expect_value(t, upd.phase, Update_Phase.Ready)
	testing.expect_value(t, upd.release.version, "0.1.1")
	testing.expect_value(t, upd.staged, "/x/.deckhand-update-0.1.1.app")
}

// 9. Install waits for the job sheet's unsaved changes, as Quit does.
@(test)
update_install_respects_job_sheet :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	u_reset()
	defer u_reset()
	defer job_sheet = {}
	run_command(Update_Env{version = "0.1.0", bundle = "/nonexistent/Deckhand.app"})
	run_command(Update_Checked{body = release_json("v0.1.1")})
	upd.phase = .Ready
	update_set_staged_for_test("/nonexistent/.deckhand-update-0.1.1.app")
	job_sheet.open = true
	job_sheet.start = "not what the sheet holds"
	r := run_command(Update_Install{}, U_UI)
	testing.expect(t, !r.ok && strings.contains(r.error, "job sheet"), r.error)
}

// ---- security review round 2 ----

// The install-time check also refuses anything writable by group or others.
@(test)
update_install_check_writable :: proc(t: ^testing.T) {
	root := u_tmp("stagew")
	defer {os.remove_all(root); delete(root, runtime.heap_allocator())}
	app := u_bundle(root, UPDATE_BUNDLE_ID, "0.1.1")
	signed := strings.clone(codesign_cdhash(app), context.temp_allocator)
	testing.expect_value(t, install_check(app, "0.1.1", signed), "")
	posix.chmod(strings.clone_to_cstring(upath(app, "Contents", "MacOS"), context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP})
	testing.expect(t, strings.contains(install_check(app, "0.1.1", signed), "writable by others"), install_check(app, "0.1.1", signed))
}

// A backup whose version is not the one running (the user went back by hand) is not kept
// forever: it goes at the second start too.
@(test)
update_backup_after_downgrade :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	u_reset()
	defer u_reset()
	dir := u_tmp("downgrade")
	defer {os.remove_all(dir); delete(dir, runtime.heap_allocator())}
	old_root := home_root
	home_root = dir
	defer home_root = old_root
	bundle := upath(dir, "Deckhand.app")
	backup := fmt.tprintf("%s.old-0.1.0", bundle)
	os.make_directory_all(bundle)
	os.make_directory_all(backup)
	update_set_backup_for_test(backup, "0.1.1")
	update_save()
	for i in 0 ..< 2 {
		u_reset()
		update_load()
		run_command(Update_Env{version = "0.1.0", bundle = bundle}) // not the version it was kept for
		if i == 0 do testing.expect(t, os.exists(backup), "kept at the first start")
	}
	testing.expect(t, !os.exists(backup), "removed at the second start, whatever version runs")
}

// What Restart to update says it does: only what is true (app tabs are among the programs that
// stop; sessions waiting for an unreachable holder keep running there, never "stopped").
@(test)
update_effects_wording :: proc(t: ^testing.T) {
	cases := []struct {
		keeps, stops, jobs, away, browsers: bool,
		want:                               string,
	} {
		{false, true, false, false, false, "Running sessions, shells and app tabs will be stopped."},
		{false, true, true, false, true, "Running sessions, shells and app tabs will be stopped; running jobs will be stopped; browser pages will reload."},
		{false, false, false, true, false, "Sessions waiting for the session holder keep running in it."},
		{false, true, false, true, false, "Running sessions, shells and app tabs will be stopped; sessions waiting for the session holder keep running in it."},
		{true, false, false, false, false, "Sessions carry on."},
		{true, false, false, false, true, "Sessions carry on; browser pages will reload."},
		{true, true, true, false, false, "Sessions kept running carry on; other tabs' programs will be stopped; running jobs will be stopped."},
	}
	for c, i in cases {
		got := update_effects_text(c.keeps, c.stops, c.jobs, c.away, c.browsers)
		testing.expectf(t, got == c.want, "case %d: %q", i, got)
		testing.expectf(t, !strings.contains(got, "restart"), "case %d: %q", i, got)
	}
}
