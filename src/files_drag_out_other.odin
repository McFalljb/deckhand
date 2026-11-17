#+build !darwin
package main

// No system drag out of the window yet (files_drag_out.odin): a tree drag that leaves the window ends.

platform_drag_out_supported :: proc() -> bool {return false}
platform_drag_out_active :: proc() -> bool {return false}
platform_drag_out_begin :: proc(paths, texts: []string, label: string) -> bool {return false}
platform_drag_out_mask :: proc(outside_app: bool) -> int {return 0}
platform_drag_out_test_items :: proc(paths, texts: []string) -> (string, bool) {return "", false}
