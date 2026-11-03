#+build darwin
package main

// macOS side of the editor and file-system model (src/native/editor_macos.m):
// the FSEvents watcher, the Trash and Finder.

import "core:c"
import "core:strings"

foreign import pdeditor {
	"../build/pd_editor.a",
	"system:CoreServices.framework",
	"system:Cocoa.framework",
}

@(default_calling_convention = "c")
foreign pdeditor {
	pd_fsw_set :: proc(paths: [^]cstring, n: c.int, cb: proc "c" (path: cstring, flags: u32)) ---
	pd_trash :: proc(path: cstring) -> c.int ---
	pd_reveal :: proc(path: cstring) ---
}

// Watches these folders (recursively); events arrive on another thread.
fs_watch_set :: proc(folders: []string, cb: proc "c" (path: cstring, flags: u32)) {
	cs := make([]cstring, len(folders), context.temp_allocator)
	for f, i in folders do cs[i] = strings.clone_to_cstring(f, context.temp_allocator)
	pd_fsw_set(raw_data(cs), c.int(len(cs)), cb)
}

fs_trash :: proc(path: string) -> bool {return pd_trash(strings.clone_to_cstring(path, context.temp_allocator)) == 0}
fs_reveal :: proc(path: string) {pd_reveal(strings.clone_to_cstring(path, context.temp_allocator))}
