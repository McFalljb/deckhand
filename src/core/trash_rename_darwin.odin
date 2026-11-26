#+build darwin
package core

// trash_xdg's move (tested on macOS; its Trash is Finder's): renamex_np(RENAME_EXCL), so a file
// another process put at that name meanwhile is never replaced.

import "core:c"
import "core:sys/posix"

foreign import libc "system:System"

@(private = "file")
RENAME_EXCL :: 0x4

@(default_calling_convention = "c", private = "file")
foreign libc {
	renamex_np :: proc(from, to: cstring, flags: c.uint) -> c.int ---
}

trash_rename :: proc(from, to: cstring) -> Trash_Rename {
	if renamex_np(from, to, RENAME_EXCL) == 0 do return .Ok
	#partial switch posix.errno() {
	case .EEXIST: return .Exists
	case .EXDEV:  return .Other_Disk
	}
	return .Failed
}
