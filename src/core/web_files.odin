package core

// A browser's files (#148): it views and edits a project's text files in the session's editor and
// Markdown tabs. The window keeps those tabs' text in its own editor (editor_*.odin, in the window
// process); a browser has none, so it reads and saves through these two queries. Only a paired
// browser may send them (caller_from_web), and only for a file inside a project folder of this
// machine (fs_check: not a project folder itself, nothing in .git), never a credentials file or
// what `deckhand show` refuses an agent (settings_credential, credential_inode, show_secret), no
// device, network or removable volume, no binary, at most WEB_FILE_MAX bytes, UTF-8 text only.
// Links: the file is read and replaced through its folder's descriptor (openat, NOFOLLOW), whose
// real path is checked again (as pi_handoff checks the file it sends), so a link swapped in
// after the check leads nowhere outside. Their text is never in an event or the log.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"
import "core:crypto"
import "core:encoding/hex"
import "core:encoding/base64"

WEB_FILE_MAX :: 4 << 20 // a file a browser views or saves: at most this many bytes

// Reads a project's text file for a browser's editor or Markdown tab. since: the hash the
// browser has; the same file answers {same: true} without its text.
File_Read :: struct {
	path:  string, // absolute
	since: string,
	image: bool, // the bytes of a PNG, JPEG, GIF, BMP or WebP (base64, its type from its first bytes) instead of text
}

// Saves a browser's edit of a project's text file (an existing regular file, replaced atomically,
// its permissions kept). base: the hash it read; a file changed on disk since is refused
// (data.code "changed") unless force.
File_Save :: struct {
	path:  string, // absolute
	text:  string,
	base:  string,
	force: bool,
}

@(private = "file")
PERM :: posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}

// The checks both share, on the path as given: a browser's, absolute, not a device or slow
// volume, not a secret by name; then where it really is (rp) inside a project folder.
@(private = "file")
web_file_where :: proc(path: string, caller: Caller, read := false) -> (p, dir, name: string, err: string) {
	if !caller_from_web(caller) do return "", "", "", "only a browser reads and saves files this way (the window has its editor)"
	if path == "" || !filepath.is_abs(path) do return "", "", "", "give the file's absolute path"
	p, _ = filepath.clean(path, context.temp_allocator)
	if show_device(p) || show_slow_path(p) do return "", "", "", "not on a device, network or removable volume"
	name = filepath.base(p)
	if name == "" || name == "." || name == ".." || name == "/" do return "", "", "", "not a file name"
	dir = fs_real(filepath.dir(p))
	rp := strings.concatenate({strings.trim_right(dir, "/"), "/", name}, context.temp_allocator)
	if show_device(rp) || show_slow_path(rp) do return "", "", "", "not on a device, network or removable volume"
	if settings_credential(p) || settings_credential(rp) do return "", "", "", CREDENTIAL_REFUSED
	if show_secret(p) || show_secret(rp) do return "", "", "", "it looks like a secret (keys, tokens, sign-ins): not opened in a browser"
	if ferr := fs_check_err(rp, caller, read); ferr != "" do return "", "", "", ferr // a read: a listed checkout of a known project too (fs_read.odin)
	// .git in any case, at any component (a case-insensitive volume opens .GIT as .git; a
	// worktree's .git is a file naming its gitdir)
	for q in ([]string{p, rp}) do for part in strings.split(q, "/", context.temp_allocator) {
		if strings.equal_fold(part, ".git") do return "", "", "", "not inside .git"
	}
	return p, dir, name, ""
}

// A file's bytes as a browser may have them: not binary, UTF-8 ("" = fine).
@(private = "file")
web_file_text_err :: proc(data: []u8) -> string {
	if looks_binary(data[:min(len(data), 8192)]) do return "Binary file: not shown"
	if !utf8.valid_string(string(data)) do return "not UTF-8 text: not shown in a browser"
	return ""
}

// The folder, opened without following a link, and its real path checked again: the file is then
// reached only through it (openat).
@(private = "file")
web_file_dir :: proc(dir, name: string, caller: Caller, read := false) -> (fd: posix.FD, err: string) {
	fd = posix.open(strings.clone_to_cstring(dir, context.temp_allocator), {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if fd < 0 do return -1, "cannot open its folder"
	at := fd_real_path(fd)
	full := strings.concatenate({strings.trim_right(at, "/"), "/", name}, context.temp_allocator)
	if ferr := fs_check_err(full, caller, read); at == "" || ferr != "" {
		posix.close(fd)
		return -1, ferr != "" ? ferr : "cannot tell where its folder is"
	}
	return fd, ""
}

// What the last read of a file saw (its folder's real path and name): its inode, size, change
// and modification times, and its hash. A poll that brings that hash, for a file whose fstat
// still says the same, is answered "same" without reading it (an open 4 MB file was read and hashed
// every 2.5 s). At most WEB_FILE_SEEN_MAX files; then it starts again.
@(private = "file")
Web_File_Seen :: struct {
	dev, ino:     u64,
	size:         i64,
	mtime, ctime: [2]i64,
	hash:         string, // heap
}
@(private = "file")
web_file_seen: map[string]Web_File_Seen // heap keys
WEB_FILE_SEEN_MAX :: 64
web_file_reads: int // the files read in full (tests)

@(private = "file")
web_file_seen_as :: proc(st: posix.stat_t, h: string) -> Web_File_Seen {
	return {dev = u64(st.st_dev), ino = u64(st.st_ino), size = i64(st.st_size), mtime = {i64(st.st_mtim.tv_sec), i64(st.st_mtim.tv_nsec)}, ctime = {i64(st.st_ctim.tv_sec), i64(st.st_ctim.tv_nsec)}, hash = h}
}

@(private = "file")
web_file_remember :: proc(key: string, st: posix.stat_t, h: string) {
	context.allocator = runtime.heap_allocator()
	if old, ok := web_file_seen[key]; ok {
		delete(old.hash)
		web_file_seen[key] = web_file_seen_as(st, strings.clone(h))
		return
	}
	if len(web_file_seen) >= WEB_FILE_SEEN_MAX {
		for k, v in web_file_seen {
			delete(k)
			delete(v.hash)
		}
		clear(&web_file_seen)
	}
	web_file_seen[strings.clone(key)] = web_file_seen_as(st, strings.clone(h))
}

// The file's bytes through the folder's descriptor: a regular file (not a link), not a
// credentials file by inode, at most WEB_FILE_MAX. since/key: the hash the browser has and the
// file's key (web_file_remember): the same file, as fstat says, is not read (same).
@(private = "file")
web_file_bytes :: proc(dirfd: posix.FD, name: string, since := "", key := "", limit := WEB_FILE_MAX) -> (data: []u8, st: posix.stat_t, err: string, same: bool) {
	fd := posix.openat(dirfd, strings.clone_to_cstring(name, context.temp_allocator), {.NOFOLLOW, .CLOEXEC, .NONBLOCK})
	if fd < 0 do return nil, st, posix.errno() == .ELOOP ? "a link: open the file it points to" : "no such file", false
	defer posix.close(fd)
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) do return nil, st, "not a regular file", false
	if credential_inode(u64(st.st_dev), u64(st.st_ino)) do return nil, st, CREDENTIAL_REFUSED, false
	if i64(st.st_size) > i64(limit) do return nil, st, fmt.tprintf("too large to open in a browser (%.1f MB; at most %d MB)", f64(st.st_size) / (1 << 20), limit >> 20), false
	if since != "" {
		if seen, ok := web_file_seen[key]; ok && seen == web_file_seen_as(st, since) do return nil, st, "", true
	}
	web_file_reads += 1
	buf := make([]u8, int(st.st_size) + 1, context.temp_allocator)
	n := 0
	for n < len(buf) {
		rem := len(buf) - n
		k := posix.read(fd, raw_data(buf[n:]), uint(rem))
		if k < 0 {
			if posix.errno() == .EINTR do continue
			return nil, st, "cannot read it", false
		}
		if k == 0 do break
		n += int(k)
	}
	if n > limit do return nil, st, "too large to open in a browser", false
	return buf[:n], st, "", false
}

@(private = "file")
web_file_hash :: proc(b: []u8) -> string {return fmt.tprintf("%016x", hash.fnv64a(b))}

@(private = "file")
web_file_json :: proc(path: string, st: posix.stat_t, h: string, text: Maybe(string), saved := false, image := "", b64 := "") -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"path":`)
	json_quote(&b, path)
	mtime := i64(st.st_mtim.tv_sec) * 1_000_000_000 + i64(st.st_mtim.tv_nsec)
	fmt.sbprintf(&b, `,"size":%d,"mtime":%d,"hash":"%s","markdown":%v`, i64(st.st_size), mtime, h, md_is_markdown_path(path))
	if t, has := text.?; has {
		strings.write_string(&b, `,"text":`)
		json_quote(&b, t)
	} else if image != "" {
		fmt.sbprintf(&b, `,"image":"%s","base64":"%s"`, image, b64) // a MIME type and base64: nothing to escape
	} else do strings.write_string(&b, saved ? `,"saved":true` : `,"same":true`)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

file_read_apply :: proc(c: File_Read, caller: Caller) -> Result {
	p, dir, name, err := web_file_where(c.path, caller, read = true)
	if err != "" do return fail(err)
	dirfd, derr := web_file_dir(dir, name, caller, read = true)
	if derr != "" do return fail(derr)
	defer posix.close(dirfd)
	key := strings.concatenate({strings.trim_right(fd_real_path(dirfd), "/"), "/", name}, context.temp_allocator)
	data, st, rerr, same := web_file_bytes(dirfd, name, c.since, key, c.image ? WEB_IMAGE_MAX : WEB_FILE_MAX)
	if rerr != "" do return fail(rerr)
	if same do return {ok = true, data = strings.clone(web_file_json(p, st, c.since, nil))} // unchanged since its last read
	if c.image do return web_image_read(p, key, st, data, c.since) // image_file.odin's formats, as base64
	if terr := web_file_text_err(data); terr != "" do return fail(terr)
	h := web_file_hash(data)
	web_file_remember(key, st, h)
	if c.since != "" && c.since == h do return {ok = true, data = strings.clone(web_file_json(p, st, h, nil))}
	return {ok = true, data = strings.clone(web_file_json(p, st, h, string(data)))}
}

// file_read's image: the file's bytes when they are an image (image_sniff), base64 with its type.
@(private = "file")
web_image_read :: proc(p, key: string, st: posix.stat_t, data: []u8, since: string) -> Result {
	f := image_sniff(data[:min(len(data), 16)])
	if f == .None do return fail("not an image Deckhand shows (PNG, JPEG, GIF, BMP, WebP)")
	h := web_file_hash(data)
	web_file_remember(key, st, h)
	if since != "" && since == h do return {ok = true, data = strings.clone(web_file_json(p, st, h, nil))}
	j := web_file_json(p, st, h, nil, image = IMAGE_MIME[f], b64 = base64.encode(data, allocator = context.temp_allocator))
	return {ok = true, data = strings.clone(j)}
}

file_save_apply :: proc(c: File_Save, caller: Caller) -> Result {
	if len(c.text) > WEB_FILE_MAX do return fail(fmt.tprintf("too large to save from a browser (at most %d MB)", WEB_FILE_MAX >> 20))
	if !utf8.valid_string(c.text) do return fail("not UTF-8 text")
	p, dir, name, err := web_file_where(c.path, caller)
	if err != "" do return fail(err)
	// Codex's hooks: shown, never written (codex_view_only), as in the window's editor
	if codex_view_only(p) || codex_view_only(strings.concatenate({strings.trim_right(dir, "/"), "/", name}, context.temp_allocator)) do return fail("Codex's hooks are read-only here")
	when TEST_HOOKS {
		if web_file_save_race != nil do web_file_save_race() // tests: a folder swapped after the check
	}
	dirfd, derr := web_file_dir(dir, name, caller)
	if derr != "" do return fail(derr)
	defer posix.close(dirfd)
	// again where the folder actually opened is (a folder on the way swapped for a link after the
	// checks above): never Codex's hooks nor a credentials or state file there
	if at := fd_real_path(dirfd); at != "" {
		full := strings.concatenate({strings.trim_right(at, "/"), "/", name}, context.temp_allocator)
		if codex_view_only(full) do return fail("Codex's hooks are read-only here")
		if settings_credential(full) do return fail(CREDENTIAL_REFUSED)
	} else do return fail("cannot tell where its folder is")
	// an existing regular file only (a new one: create_file), as it is now
	now, st, rerr, _ := web_file_bytes(dirfd, name)
	if rerr != "" do return fail(rerr)
	if terr := web_file_text_err(now); terr != "" do return fail(terr) // forced too: what a read refuses is not replaced
	if !c.force && c.base != web_file_hash(now) do return {error = "the file changed on disk since you opened it", data = strings.clone(`{"code":"changed"}`)}
	// a new file beside it (a short name of its own: a name near NAME_MAX saves too; 0600 until
	// its permissions are set), then renamed over it: a crash leaves the old file or the new one
	r: [8]u8
	crypto.rand_bytes(r[:])
	tmp := fmt.tprintf(".deckhand-%s.tmp", string(hex.encode(r[:], context.temp_allocator)))
	ctmp := strings.clone_to_cstring(tmp, context.temp_allocator)
	fd := posix.openat(dirfd, ctmp, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, posix.mode_t{.IRUSR, .IWUSR})
	if fd < 0 do return fail("cannot write in its folder")
	ok := true
	for off := 0; off < len(c.text) && ok; {
		rem := len(c.text) - off
		k := posix.write(fd, raw_data(c.text[off:]), uint(rem))
		if k < 0 {
			if posix.errno() == .EINTR do continue
			ok = false
			break
		}
		off += int(k)
	}
	if ok do ok = posix.fchmod(fd, st.st_mode & PERM) == .OK
	if ok do ok = posix.fsync(fd) == .OK
	posix.close(fd)
	if ok do ok = posix.renameat(dirfd, ctmp, dirfd, strings.clone_to_cstring(name, context.temp_allocator)) == .OK
	if !ok {
		posix.unlinkat(dirfd, ctmp, {})
		return fail("could not save it")
	}
	fs_model_changed(strings.concatenate({strings.trim_right(fd_real_path(dirfd), "/"), "/", name}, context.temp_allocator)) // the Files tab's and Changes' git status
	nst: posix.stat_t
	posix.fstatat(dirfd, strings.clone_to_cstring(name, context.temp_allocator), &nst, {.SYMLINK_NOFOLLOW})
	return {ok = true, data = strings.clone(web_file_json(p, nst, web_file_hash(transmute([]u8)c.text), nil, saved = true))}
}

when TEST_HOOKS {
	// Tests: runs between file_save_apply's path checks and its opening the folder (a swap there).
	web_file_save_race: proc()
}
