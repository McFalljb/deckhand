#+build linux
package core

// trash_xdg's move: renameat2(RENAME_NOREPLACE), so a file another process put at that name
// meanwhile is never replaced. A file system without it (EINVAL): a plain rename.

import "core:sys/linux"
import "core:sys/posix"

trash_rename :: proc(from, to: cstring) -> Trash_Rename {
	#partial switch linux.renameat2(linux.AT_FDCWD, from, linux.AT_FDCWD, to, {.NOREPLACE}) {
	case .NONE:   return .Ok
	case .EEXIST: return .Exists
	case .EXDEV:  return .Other_Disk
	case .EINVAL, .ENOSYS:
		if posix.rename(from, to) == 0 do return .Ok
		return posix.errno() == .EXDEV ? .Other_Disk : .Failed
	case:         return .Failed
	}
}
