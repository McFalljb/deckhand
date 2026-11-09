package core

// MAC'd state files (macfile.odin): every way a file can be wrong fails closed. Temp dirs only.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
mf_dir :: proc(t: ^testing.T, name: string) -> string {
	d := fmt.tprintf("%s/pd-mac-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), name, time.now()._nsec % 1_000_000_000)
	testing.expect(t, os.make_directory_all(d, {.Read_User, .Write_User, .Execute_User}) == nil, d)
	return d
}

@(private = "file")
mf_key :: proc(b: u8) -> (k: [32]u8) {
	for i in 0 ..< 32 do k[i] = b + u8(i)
	return
}

@(private = "file")
mf_raw :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	return string(data)
}

@(private = "file")
mf_put :: proc(path, text: string) {
	os.remove(path)
	f, _ := os.open(path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	os.write_string(f, text)
	os.close(f)
}

@(test)
macfile_round_trip :: proc(t: ^testing.T) {
	d := mf_dir(t, "rt")
	p := fmt.tprintf("%s/tokens.json", d)
	key := mf_key(1)
	ok, why := macfile_write(p, "tokens", `{"v":1}`, key[:])
	testing.expect(t, ok, why)
	st: posix.stat_t
	testing.expect(t, posix.stat(strings.clone_to_cstring(p, context.temp_allocator), &st) == .OK)
	testing.expect_value(t, transmute(u16)st.st_mode & 0o777, 0o600)
	testing.expect(t, strings.has_prefix(mf_raw(p), "deckhand-mac 1 tokens "), mf_raw(p))
	body, rok, rwhy := macfile_read(p, "tokens", key[:], context.temp_allocator)
	testing.expect(t, rok, rwhy)
	testing.expect_value(t, body, `{"v":1}`)
	// rewritten in place: the new body, no temp files left
	ok, why = macfile_write(p, "tokens", `{"v":1,"terms":[]}`, key[:])
	testing.expect(t, ok, why)
	body, rok, _ = macfile_read(p, "tokens", key[:], context.temp_allocator)
	testing.expect(t, rok && body == `{"v":1,"terms":[]}`, body)
	entries, _ := os.read_all_directory_by_path(d, context.temp_allocator)
	testing.expect_value(t, len(entries), 1)
	os.remove(p)
	os.remove(d)
}

@(test)
macfile_fails_closed :: proc(t: ^testing.T) {
	d := mf_dir(t, "fc")
	p := fmt.tprintf("%s/f.json", d)
	key, other := mf_key(1), mf_key(9)
	refused :: proc(t: ^testing.T, p, kind: string, key: []u8, want: string, loc := #caller_location) {
		body, ok, why := macfile_read(p, kind, key, context.temp_allocator)
		testing.expect(t, !ok && body == "", why, loc = loc)
		testing.expect(t, strings.contains(why, want), why, loc = loc)
	}
	refused(t, p, "tokens", key[:], "missing")
	ok, why := macfile_write(p, "tokens", `{"v":1,"a":"secret-ish"}`, key[:])
	testing.expect(t, ok, why)
	good := mf_raw(p)

	refused(t, p, "tokens", other[:], "bad MAC") // another holder's key
	refused(t, p, "handover", key[:], "not handover") // kind swap: a tokens file is never a handover file
	refused(t, p, "tokens", nil, "no key")
	// a handover file renamed to tokens.json fails too (the kind is inside the MAC)
	mf_put(p, strings.concatenate({"deckhand-mac 1 handover", good[len("deckhand-mac 1 tokens"):]}, context.temp_allocator))
	refused(t, p, "handover", key[:], "bad MAC")
	// a flipped body byte, a cut body, an appended byte
	nl := strings.index_byte(good, '\n')
	flip := transmute([]u8)strings.clone(good, context.temp_allocator)
	flip[nl + 5] ~= 1
	mf_put(p, string(flip))
	refused(t, p, "tokens", key[:], "bad MAC")
	mf_put(p, good[:len(good) - 1])
	refused(t, p, "tokens", key[:], "bad MAC")
	mf_put(p, strings.concatenate({good, " "}, context.temp_allocator))
	refused(t, p, "tokens", key[:], "bad MAC")
	// a cut header, a cut MAC, no MAC, an empty file, a flipped MAC digit
	mf_put(p, good[:nl - 3])
	refused(t, p, "tokens", key[:], "no header")
	mf_put(p, strings.concatenate({good[:nl - 3], good[nl:]}, context.temp_allocator))
	refused(t, p, "tokens", key[:], "bad MAC")
	mf_put(p, strings.concatenate({"deckhand-mac 1 tokens", good[nl:]}, context.temp_allocator))
	refused(t, p, "tokens", key[:], "not a MAC'd state file")
	mf_put(p, "")
	refused(t, p, "tokens", key[:], "no header")
	mac := transmute([]u8)strings.clone(good, context.temp_allocator)
	mac[nl - 1] = mac[nl - 1] == '0' ? '1' : '0'
	mf_put(p, string(mac))
	refused(t, p, "tokens", key[:], "bad MAC")
	// an unknown format version, plain JSON (an old or hand-written file)
	mf_put(p, strings.concatenate({"deckhand-mac 2", good[len("deckhand-mac 1"):]}, context.temp_allocator))
	refused(t, p, "tokens", key[:], "unknown format")
	mf_put(p, `{"v":1}`)
	refused(t, p, "tokens", key[:], "no header")
	// oversized
	mf_put(p, good)
	was := macfile_max
	macfile_max = 8
	refused(t, p, "tokens", key[:], "too large")
	macfile_max = was
	os.remove(p)
	os.remove(d)
}

@(test)
macfile_refuses_symlinks :: proc(t: ^testing.T) {
	d := mf_dir(t, "ln")
	p := fmt.tprintf("%s/tokens.json", d)
	target := fmt.tprintf("%s/elsewhere", d)
	key := mf_key(1)
	ok, why := macfile_write(target, "tokens", `{}`, key[:])
	testing.expect(t, ok, why)
	testing.expect(t, posix.symlink(strings.clone_to_cstring(target, context.temp_allocator), strings.clone_to_cstring(p, context.temp_allocator)) == .OK)
	_, rok, rwhy := macfile_read(p, "tokens", key[:], context.temp_allocator)
	testing.expect(t, !rok, "read through a symlink")
	_ = rwhy
	wok, _ := macfile_write(p, "tokens", `{"x":1}`, key[:])
	testing.expect(t, !wok, "wrote through a symlink")
	testing.expect(t, strings.has_suffix(mf_raw(target), "\n{}"), "the target is untouched")
	os.remove(p)
	os.remove(target)
	os.remove(d)
}

@(test)
json_shape_limits :: proc(t: ^testing.T) {
	testing.expect(t, json_shape_ok(`{"a":[1,2,3],"b":"x,y:z"}`, 10))
	testing.expect(t, !json_shape_ok(`{"a":[1,2,3],"b":4}`, 3))
	testing.expect(t, json_shape_ok(`{"s":",,,,,,,,,,,,,,,,,,,"}`, 2), "commas in strings do not count")
	deep := strings.concatenate({strings.repeat("[", JSON_MAX_DEPTH + 1, context.temp_allocator), strings.repeat("]", JSON_MAX_DEPTH + 1, context.temp_allocator)}, context.temp_allocator)
	testing.expect(t, !json_shape_ok(deep, 1 << 20))
	testing.expect(t, !json_shape_ok("{\"a\":\"\xff\xfe\"}", 10), "invalid UTF-8 (json.parse would trap on it)")
}
