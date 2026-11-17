#+build darwin
package main

// macOS side of the editor and file-system model (src/native/editor_macos.m):
// the FSEvents watcher, the Trash and Finder.

import "core:c"
import "core:strings"

import "core"

foreign import pdeditor {
	"../build/dh_editor.a",
	"system:CoreServices.framework",
	"system:Cocoa.framework",
}

@(default_calling_convention = "c")
foreign pdeditor {
	dh_fsw_set :: proc(paths: [^]cstring, n: c.int, cb: proc "c" (path: cstring, flags: u32)) ---
	dh_trash :: proc(path: cstring, where_: [^]u8, where_len: c.int) -> c.int ---
	dh_reveal :: proc(path: cstring) ---
}

// Watches these folders (recursively); events arrive on another thread.
fs_watch_set :: proc(folders: []string, cb: proc "c" (path: cstring, flags: u32)) {
	cs := make([]cstring, len(folders), context.temp_allocator)
	for f, i in folders do cs[i] = strings.clone_to_cstring(f, context.temp_allocator)
	dh_fsw_set(raw_data(cs), c.int(len(cs)), cb)
}

// Moves path to the Trash; where it went is core.fs_trash_where (restore_path).
fs_trash :: proc(path: string) -> bool {
	buf: [4096]u8
	if dh_trash(strings.clone_to_cstring(path, context.temp_allocator), raw_data(buf[:]), c.int(len(buf))) != 0 do return false
	if buf[0] != 0 do core.fs_trash_where = strings.clone(string(cstring(raw_data(buf[:]))), context.temp_allocator)
	return true
}
fs_reveal :: proc(path: string) {dh_reveal(strings.clone_to_cstring(path, context.temp_allocator))}
