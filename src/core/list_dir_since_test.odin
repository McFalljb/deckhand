package core

// list_dir since (editor_commands_core.odin): the answer carries its hash; asked again with it, an
// unchanged folder answers same with no entries; a change in the folder answers in full. Old
// callers (no since) get the entries as before, with the hash added.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(test)
list_dir_since_same_until_changed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	tmpl := strings.clone_to_cstring(fmt.tprintf("%s/ld-XXXXXX", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")), context.temp_allocator)
	proj := fs_real(fmt.tprintf("%s/p,\"q", string(posix.mkdtemp(([^]u8)(tmpl))))) // a comma and a quote in the path
	os.make_directory_all(fmt.tprintf("%s/src", proj))
	_ = os.write_entire_file(fmt.tprintf("%s/a.txt", proj), transmute([]u8)string("a"))
	append(&state.projects, Project{id = new_id(), group = .Projects, cwd = strings.clone(proj)})
	web := Caller{kind = .UI, web = true}

	ask :: proc(path, since: string, by: Caller) -> (json.Object, Result) {
		r := run_command(List_Dir{path = path, since = since}, by)
		if !r.ok do return nil, r
		v, _ := json.parse_string(r.data, allocator = context.temp_allocator)
		return v.(json.Object), r
	}
	o, r := ask(proj, "", web)
	testing.expect(t, r.ok && o != nil, r.error)
	if o == nil do return
	testing.expect_value(t, o["path"].(json.String), proj)
	testing.expect(t, len(o["entries"].(json.Array)) == 2, r.data)
	h := strings.clone(o["hash"].(json.String), context.temp_allocator)
	testing.expect_value(t, len(h), 16)

	// unchanged: same, the path, no entries
	o2, r2 := ask(proj, h, web)
	testing.expect(t, o2 != nil && o2["same"] != nil && o2["entries"] == nil, r2.data)
	if o2 != nil do testing.expect_value(t, o2["path"].(json.String), proj)
	// another hash (or an old client's none): in full
	o3, _ := ask(proj, "0000000000000000", web)
	testing.expect(t, o3 != nil && o3["same"] == nil && o3["entries"] != nil, "a stale hash lists it")

	// a new file: in full, a new hash
	_ = os.write_entire_file(fmt.tprintf("%s/b.txt", proj), transmute([]u8)string("b"))
	o4, r4 := ask(proj, h, web)
	testing.expect(t, o4 != nil && o4["same"] == nil && len(o4["entries"].(json.Array)) == 3, r4.data)
	if o4 != nil do testing.expect(t, o4["hash"].(json.String) != h, "a new hash")

	// the wire: since is read and written back (the core's request to a holder or the window)
	cmd, err := parse_command(`{"type":"list_dir","path":"/x","since":"abc"}`)
	testing.expect_value(t, err, "")
	if ld, ok := cmd.(List_Dir); ok do testing.expect_value(t, ld.since, "abc")
	else do testing.expect(t, false, "not a List_Dir")
}
