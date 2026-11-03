#+build !darwin
package main

// Stubs until Linux/Windows get a watcher (the editor's stat poll still
// follows open files), a trash and a file manager hook.

fs_watch_set :: proc(folders: []string, cb: proc "c" (path: cstring, flags: u32)) {}
fs_trash :: proc(path: string) -> bool {return false}
fs_reveal :: proc(path: string) {}
