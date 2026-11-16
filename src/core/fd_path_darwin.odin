package core

import "core:strings"
import "core:sys/posix"

// The real path of the file open on fd, as the kernel has it now (fcntl F_GETPATH; temp), or "".
// What a path was checked against before an open can change under it: this is what was opened.
fd_real_path :: proc(fd: posix.FD) -> string {
	F_GETPATH :: 50 // <sys/fcntl.h>
	buf: [posix.PATH_MAX]u8
	if posix.fcntl(fd, posix.FCNTL_Cmd(F_GETPATH), raw_data(buf[:])) == -1 do return ""
	return strings.clone(string(cstring(raw_data(buf[:]))), context.temp_allocator)
}
