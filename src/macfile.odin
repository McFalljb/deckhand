package main

// State files authenticated with the session holder's HMAC key (docs/plans/background-core.md
// §5.3, B3): tokens.json (socket.odin) and handover.json. The key lives in the holder's memory
// only and comes in its WELCOME, so a file written by anyone without it does not verify.
//
// Format: one header line, then the body (JSON, as the caller wrote it):
//
//     deckhand-mac 1 <kind> <64 hex: HMAC-SHA256>\n<body>
//
// The MAC covers `deckhand-mac 1 <kind>\n` + the body, so a file of one kind ("tokens",
// "handover") never verifies as another, and a cut or edited body never verifies at all.
// Reading fails closed: a missing, unreadable, oversized, symlinked or not-regular file, a bad
// header, an unknown format version, a wrong kind and a bad MAC all give ok = false and nothing.

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

MACFILE_MAGIC :: "deckhand-mac"
MACFILE_VERSION :: 1
MACFILE_KEY_LEN :: 32 // the holder's key: 256 bits
macfile_max := 1 << 20 // the largest body read (tests lower it)

@(private = "file")
macfile_kind_ok :: proc(kind: string) -> bool {
	if kind == "" || len(kind) > 32 do return false
	for i in 0 ..< len(kind) do if !(kind[i] >= 'a' && kind[i] <= 'z') do return false
	return true
}

@(private = "file")
macfile_tag :: proc(kind, body: string, key: []u8, dst: []u8) {
	ctx: hmac.Context
	hmac.init(&ctx, .SHA256, key)
	hmac.update(&ctx, transmute([]u8)fmt.tprintf("%s %d %s\n", MACFILE_MAGIC, MACFILE_VERSION, kind))
	hmac.update(&ctx, transmute([]u8)body)
	hmac.final(&ctx, dst)
}

// Writes `body` to `path` MAC'd as `kind`: a 0600 temp file beside it (O_EXCL, O_NOFOLLOW),
// fsync, rename. Refuses a path that is a symlink or not a regular file, and a key that is not
// 32 bytes.
macfile_write :: proc(path, kind, body: string, key: []u8) -> (ok: bool, why: string) {
	if len(key) != MACFILE_KEY_LEN do return false, "no key"
	if !macfile_kind_ok(kind) do return false, "bad kind"
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st: posix.stat_t
	if posix.lstat(cpath, &st) == .OK && !posix.S_ISREG(st.st_mode) do return false, "not a regular file (a symlink?)"
	tag: [32]u8
	macfile_tag(kind, body, key, tag[:])
	header := fmt.tprintf("%s %d %s %s\n", MACFILE_MAGIC, MACFILE_VERSION, kind, string(hex.encode(tag[:], context.temp_allocator)))
	rnd: [8]u8
	crypto.rand_bytes(rnd[:])
	tmp := fmt.tprintf("%s.tmp-%s", path, string(hex.encode(rnd[:], context.temp_allocator)))
	ctmp := strings.clone_to_cstring(tmp, context.temp_allocator)
	fd := posix.open(ctmp, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 do return false, fmt.tprintf("cannot create %s: %s", tmp, posix.strerror(posix.errno()))
	good := macfile_write_all(fd, header) && macfile_write_all(fd, body) && posix.fsync(fd) == .OK
	posix.close(fd)
	if good do good = posix.rename(ctmp, cpath) == 0
	if !good {
		why = fmt.tprintf("cannot write %s: %s", path, posix.strerror(posix.errno()))
		posix.unlink(ctmp)
		return false, why
	}
	return true, ""
}

@(private = "file")
macfile_write_all :: proc(fd: posix.FD, s: string) -> bool {
	b := transmute([]u8)s
	for len(b) > 0 {
		n := posix.write(fd, raw_data(b), uint(len(b)))
		if n < 0 {
			if posix.errno() == .EINTR do continue
			return false
		}
		b = b[n:]
	}
	return true
}

// The body of `path` if it verifies as `kind` under `key` (allocator), else ok = false and why.
macfile_read :: proc(path, kind: string, key: []u8, allocator := context.allocator) -> (body: string, ok: bool, why: string) {
	if len(key) != MACFILE_KEY_LEN do return "", false, "no key"
	if !macfile_kind_ok(kind) do return "", false, "bad kind"
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NOFOLLOW, .CLOEXEC, .NONBLOCK})
	if fd < 0 do return "", false, posix.errno() == .ENOENT ? "missing" : fmt.tprintf("cannot open: %s", posix.strerror(posix.errno()))
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) do return "", false, "not a regular file"
	header_max := len(MACFILE_MAGIC) + 2 + 4 + len(kind) + 1 + 64 + 1 + 8
	if int(st.st_size) > macfile_max + header_max do return "", false, "too large"
	data := make([]u8, int(st.st_size) + 1, context.temp_allocator) // +1: notices a file that grew
	got := 0
	for got < len(data) {
		room := len(data) - got
		n := posix.read(fd, &data[got], uint(room))
		if n < 0 {
			if posix.errno() == .EINTR do continue
			return "", false, "cannot read"
		}
		if n == 0 do break
		got += n
	}
	if got > int(st.st_size) do return "", false, "changed while read"
	text := string(data[:got])
	nl := strings.index_byte(text, '\n')
	if nl < 0 do return "", false, "no header"
	fields := strings.fields(text[:nl], context.temp_allocator)
	if len(fields) != 4 || fields[0] != MACFILE_MAGIC do return "", false, "not a MAC'd state file"
	if fields[1] != fmt.tprint(MACFILE_VERSION) do return "", false, fmt.tprintf("unknown format %s", fields[1])
	if fields[2] != kind do return "", false, fmt.tprintf("a %s file, not %s", fields[2], kind)
	want, hok := hex.decode(transmute([]u8)fields[3], context.temp_allocator)
	if !hok || len(want) != 32 do return "", false, "bad MAC"
	rest := text[nl + 1:]
	if len(rest) > macfile_max do return "", false, "too large"
	tag: [32]u8
	macfile_tag(kind, rest, key, tag[:])
	if crypto.compare_constant_time(tag[:], want) != 1 do return "", false, "bad MAC"
	return strings.clone(rest, allocator), true, ""
}

// Whether a JSON text read from outside is small enough in shape to parse: arrays and objects
// nest at most JSON_MAX_DEPTH deep (json_depth_ok) and it has at most `max_items` values and
// keys (commas and colons outside strings), and it is valid UTF-8 (core:encoding/json's string
// unquoting writes past its buffer on invalid UTF-8: a bounds trap). Run before json.parse, after
// the MAC verified.
json_shape_ok :: proc(text: string, max_items: int) -> bool {
	if !utf8.valid_string(text) || !json_depth_ok(text) do return false
	n := 0
	in_str, esc := false, false
	for i in 0 ..< len(text) {
		b := text[i]
		if in_str {
			if esc do esc = false
			else if b == '\\' do esc = true
			else if b == '"' do in_str = false
			continue
		}
		switch b {
		case '"':      in_str = true
		case ',', ':':
			n += 1
			if n > max_items do return false
		}
	}
	return true
}

// SHA-256 of a token: what state files hold instead of it.
token_hash :: proc(tok: string) -> (h: [32]u8) {
	hash.hash_string_to_buffer(.SHA256, tok, h[:])
	return
}
