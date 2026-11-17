package core

// The Linux core's Trash (src/coremain/platform_linux.odin's dh_core_trash): the freedesktop.org
// Trash spec's home trash, $XDG_DATA_HOME/Trash (else ~/.local/share/Trash). The file moves to
// files/<name> and info/<name>.trashinfo says where it was and when, so a file manager can put it
// back. Only a rename on one file system: a path on another (another mount, a removable disk) is
// refused, never deleted for good nor copied. Plain POSIX, so it builds and is tested on macOS too.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

Trash_Rename :: enum u8 {
	Ok,
	Exists, // something is at the new name: try another
	Other_Disk,
	Failed,
}

TRASH_OTHER_DISK :: "it is on another disk than your Trash: not moved (and nothing deleted)"

// The home trash folder ("" = no home folder).
trash_xdg_dir :: proc() -> string {
	d := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if d == "" || !filepath.is_abs(d) {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" do return ""
		d = strings.concatenate({strings.trim_right(home, "/"), "/.local/share"}, context.temp_allocator)
	}
	return strings.concatenate({strings.trim_right(d, "/"), "/Trash"}, context.temp_allocator)
}

// Moves path (absolute) into the home trash. "" = moved; else why not (a temp string).
trash_xdg :: proc(path: string) -> string {
	trash := trash_xdg_dir()
	if trash == "" do return "no home folder for the Trash"
	files := strings.concatenate({trash, "/files"}, context.temp_allocator)
	info := strings.concatenate({trash, "/info"}, context.temp_allocator)
	// with its parents (a fresh host has no ~/.local/share), each made 0700; there already is fine
	for d in ([]string{files, info}) do os.make_directory_all(d, {.Read_User, .Write_User, .Execute_User})
	if path_kind(files) != .Dir || path_kind(info) != .Dir do return "cannot make the Trash folder"
	// one file system: a rename, never a copy (checked first, and again by rename's EXDEV)
	sp, sf: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &sp) != .OK do return "no such file or folder"
	if posix.stat(strings.clone_to_cstring(files, context.temp_allocator), &sf) != .OK do return "cannot read the Trash folder"
	if sp.st_dev != sf.st_dev do return TRASH_OTHER_DISK
	base := filepath.base(path)
	for n in 1 ..< 1000 {
		name := n == 1 ? base : fmt.tprintf("%s.%d", base, n)
		ipath := strings.clone_to_cstring(fmt.tprintf("%s/%s.trashinfo", info, name), context.temp_allocator)
		fpath := strings.clone_to_cstring(fmt.tprintf("%s/%s", files, name), context.temp_allocator)
		// the info file is made first, exclusively: it reserves the name (the spec's order)
		fd := posix.open(ipath, {.WRONLY, .CREAT, .EXCL, .CLOEXEC, .NOFOLLOW}, {.IRUSR, .IWUSR})
		if fd < 0 {
			if posix.errno() == .EEXIST do continue
			return "cannot write to the Trash"
		}
		st: posix.stat_t
		if posix.lstat(fpath, &st) == .OK { 	// a file left there without its info: another name
			posix.close(fd)
			posix.unlink(ipath)
			continue
		}
		text := trash_info_text(path, time.now())
		ok := posix.write(fd, raw_data(text), uint(len(text))) == len(text)
		posix.close(fd)
		if !ok {
			posix.unlink(ipath)
			return "cannot write to the Trash"
		}
		// never over a file put at that name meanwhile (trash_rename_*.odin: no-replace)
		switch trash_rename(strings.clone_to_cstring(path, context.temp_allocator), fpath) {
		case .Ok:         return ""
		case .Exists:     posix.unlink(ipath); continue
		case .Other_Disk: posix.unlink(ipath); return TRASH_OTHER_DISK
		case .Failed:     posix.unlink(ipath); return "cannot move it to the Trash"
		}
	}
	return "the Trash has too many items of that name"
}

// A .trashinfo file's text: Path percent-encoded (bytes other than unreserved ones and /),
// DeletionDate in local time.
trash_info_text :: proc(path: string, at: time.Time) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[Trash Info]\nPath=")
	for i in 0 ..< len(path) {
		c := path[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~', '/':
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	secs := posix.time_t(time.time_to_unix(at))
	lt: posix.tm
	posix.localtime_r(&secs, &lt)
	fmt.sbprintf(&b, "\nDeletionDate=%04d-%02d-%02dT%02d:%02d:%02d\n", int(lt.tm_year) + 1900, int(lt.tm_mon) + 1, int(lt.tm_mday), int(lt.tm_hour), int(lt.tm_min), int(lt.tm_sec))
	return strings.to_string(b)
}
