package core

// A browser's "projects" section (#148 performance): what the page reads of each project, not the
// window's whole Project; a window's link still gets the whole one.

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:testing"
import cw "../corewire"

@(private = "file")
wp_end: cw.Mem_End

@(test)
web_projects_trimmed_for_a_browser :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	saved := state
	defer state = saved
	state = State{}
	append(&state.projects, Project{id = 7, group = .Projects, name = strings.clone("api"), cwd = strings.clone("/h/code/api"), label = strings.clone("~/code/api"), dir = strings.clone("/h/.pi/agent/sessions/--h-code-api--"), repo = true, group_dir = strings.clone("/h/code")})
	append(&state.projects, Project{id = 8, group = .Chats, cwd = strings.clone("/h/Chats"), label = strings.clone("~/Chats"), missing = true, parent = 7})
	state.selected_project = 7
	projects_of :: proc() -> string {
		for x in state_sections(&state) do if x[0] == "projects" do return x[1]
		return ""
	}
	whole := projects_of() // no link: the window's whole Project
	testing.expect(t, strings.contains(whole, `"dir":`) && strings.contains(whole, `"group_dir":`), whole)
	ok: bool
	wp_end, ok = core_attach_window(proc() {})
	if !testing.expect(t, ok, "attached") do return
	defer core_detach_window()
	testing.expect(t, projects_of() == whole, "a window's link: the whole one")
	window_link_for_test().web = true
	trimmed := projects_of()
	testing.expect(t, !strings.contains(trimmed, `"dir":`) && !strings.contains(trimmed, `"group_dir":`) && !strings.contains(trimmed, `"newest":`) && len(trimmed) < len(whole), trimmed)
	v, err := json.parse_string(trimmed, allocator = context.temp_allocator)
	if !testing.expect(t, err == nil, trimmed) do return
	o := v.(json.Object)
	testing.expect_value(t, o["selected_project"].(json.Float), 7)
	ps := o["projects"].(json.Array)
	testing.expect_value(t, len(ps), 2)
	a, c := ps[0].(json.Object), ps[1].(json.Object)
	testing.expect(t, a["id"].(json.Float) == 7 && a["group"].(json.String) == "projects" && a["name"].(json.String) == "api" && a["cwd"].(json.String) == "/h/code/api" && a["label"].(json.String) == "~/code/api" && a["repo"].(json.Boolean), trimmed)
	testing.expect(t, c["group"].(json.String) == "chats" && c["missing"].(json.Boolean) && c["parent"].(json.Float) == 7 && c["machine"].(json.Float) == 0, trimmed)
	// the same group words as the whole section
	testing.expect(t, strings.contains(whole, `"group":"projects"`) && strings.contains(whole, `"group":"chats"`), whole)
}
