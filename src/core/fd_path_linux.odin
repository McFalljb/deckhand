#+build linux
package core

import "core:fmt"
import "core:strings"
import "core:sys/posix"

// The real path of the file open on fd, as the kernel has it now (/proc/self/fd/<fd>; temp), or "".
// What a path was checked against before an open can change under it: this is what was opened.
fd_real_path :: proc(fd: posix.FD) -> string {
	buf: [posix.PATH_MAX]u8
	n := posix.readlink(strings.clone_to_cstring(fmt.tprintf("/proc/self/fd/%d", fd), context.temp_allocator), raw_data(buf[:]), len(buf) - 1)
	if n <= 0 || strings.has_suffix(string(buf[:n]), " (deleted)") do return ""
	return strings.clone(string(buf[:n]), context.temp_allocator)
}
