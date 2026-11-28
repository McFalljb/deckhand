package core

// Google's Antigravity CLI (agy), as pi's bundled antigravity extension finds it
// (integrations/pi/lib/acp.ts findAgy): the path saved by `/antigravity path` in
// <data dir>/antigravity/accounts.json when it is an executable file, else `agy` on the PATH new
// tabs get. Its version is the one agy last reported to the extension (agy-seen.json), trusted only
// while the binary has the size and mtime recorded with it. Stat and two small JSON reads: agy is
// never run. The Settings row's Install agy… / Update agy… is agy_install.odin (docs/HARNESSES.md §3a, §6).

import "core:encoding/json"
import jg "../jsonguard"
import "core:os"
import "core:path/filepath"
import "core:strings"

AGY_MIN_VERSION :: "1.5.1" // lib/acp.ts AGY_MIN_VERSION
AGY_RECOMMENDED_VERSION :: "1.5.18" // lib/acp.ts AGY_RECOMMENDED_VERSION
AGY_INSTALL_URL :: "https://antigravity.google/docs/getting-started"
AGY_MISSING_TEXT :: "Not installed: install agy " + AGY_RECOMMENDED_VERSION + "+ from " + AGY_INSTALL_URL
@(private = "file")
AGY_JSON_MAX :: 64 * 1024

// The folder the extension keeps its accounts in (lib/agy-accounts.ts dataRoot).
agy_root :: proc() -> string {
	d := data_dir(context.temp_allocator)
	return d != "" ? strings.concatenate({d, "/antigravity"}, context.temp_allocator) : ""
}

@(private = "file")
agy_json :: proc(path: string) -> json.Object {
	k, st := path_stat(path)
	if k != .File || st.size > AGY_JSON_MAX do return nil
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return nil
	v, jerr := jg.parse(data, .JSON, true, context.temp_allocator)
	if jerr != nil do return nil
	o, _ := v.(json.Object)
	return o
}

// agy and its version as the extension would find it ("" = none, or unknown). Temp.
// Unit tests look only where they say (an agy the developer installed must not change what they
// see); scenes search the scene's own PATH and data dir (detect_path is "" in test mode).
agy_detect :: proc(root := "", path := "") -> (bin, version: string) {
	when TEST_HOOKS {
		if ODIN_TEST && root == "" && path == "" do return
	}
	root := root != "" ? root : agy_root()
	path := path != "" ? path : detect_path()
	if root != "" {
		if o := agy_json(strings.concatenate({root, "/accounts.json"}, context.temp_allocator)); o != nil {
			if s, ok := o["agyPath"].(json.String); ok && filepath.is_abs(s) && exe_in(filepath.dir(s), filepath.base(s)) do bin = strings.clone(s, context.temp_allocator)
		}
	}
	if bin == "" {
		for dir in strings.split(path, ":", context.temp_allocator) do if exe_in(dir, "agy") {
			bin = strings.concatenate({strings.trim_right(dir, "/"), "/agy"}, context.temp_allocator)
			break
		}
	}
	if bin == "" || root == "" do return
	o := agy_json(strings.concatenate({root, "/agy-seen.json"}, context.temp_allocator))
	if o == nil do return
	p, _ := o["path"].(json.String)
	v, _ := o["version"].(json.String)
	size, _ := o["size"].(json.Integer)
	mtime, _ := o["mtime"].(json.Integer)
	if p != bin || v == "" do return
	k, st := path_stat(bin)
	if k != .File || i64(size) != st.size || i64(mtime) != st.mtime / 1_000_000_000 do return
	return bin, strings.clone(v, context.temp_allocator)
}
