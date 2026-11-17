package core

// The browser's "web" state section (web_view.odin): its rows from State, and that it is computed
// again only when something it reads changed. Same rules as core_test.odin: shared global State,
// one thread, no processes.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
web_view_section :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	p := Project{id = new_id(), group = .Projects, cwd = "/tmp/web-view-alpha"}
	append(&state.projects, p)
	s := Open_Session{id = new_id(), project_id = p.id, pi_session_id = "pi-alpha", cwd = p.cwd}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle, waiting = true})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)

	// the sections: the small part, the open session's row, the tree and its row
	sec :: proc(list: [][2]string, name: string) -> (string, bool) {
		for x in list do if x[0] == name do return x[1], true
		return "", false
	}
	parse :: proc(j: string) -> json.Value {
		v, err := json.parse_string(j, allocator = context.temp_allocator)
		if err != nil do return nil
		return v
	}
	secs := state_sections(&state)
	out := web_view_cached(secs[:])
	snap := make(map[string]string, context.temp_allocator)
	for x in out do snap[strings.clone(x[0], context.temp_allocator)] = strings.clone(x[1], context.temp_allocator) // the cache frees its own on a recompute
	w, _ := sec(out, "web")
	o := parse(w).(json.Object)
	open := o["open"].(json.Array)
	testing.expect_value(t, len(open), 1)
	testing.expect_value(t, u64(open[0].(json.Float)), s.id)
	testing.expect_value(t, int(o["fleet"].(json.Object)["waiting"].(json.Float)), 1)
	ws, has := sec(out, fmt.tprintf("webo:%d", s.id))
	testing.expect(t, has, "the open session's row")
	ti := parse(ws).(json.Object)
	testing.expect_value(t, ti["title"].(json.String), "Untitled session")
	testing.expect_value(t, ti["place"].(json.String), "web-view-alpha")
	testing.expect_value(t, ti["at"].(json.Float), 0)
	tree, _ := sec(out, "webtree")
	testing.expect_value(t, tree, fmt.tprintf(`["%d"]`, p.id))
	row, _ := sec(out, fmt.tprintf("webp:%d", p.id))
	testing.expect_value(t, parse(row).(json.Object)["path"].(json.String), "/tmp/web-view-alpha")

	// unchanged inputs: not computed again; a status flip: computed again, and of the browser's
	// sections only the small one changed (no tree row, no title row)
	n := web_view_last.builds
	_ = web_view_cached(secs[:])
	testing.expect_value(t, web_view_last.builds, n)
	state.open_sessions[0].tabs[0].waiting = false
	secs2 := state_sections(&state)
	out2 := web_view_cached(secs2[:])
	testing.expect_value(t, web_view_last.builds, n + 1)
	changed := make([dynamic]string, context.temp_allocator)
	for x in out2 do if snap[x[0]] != x[1] do append(&changed, x[0])
	testing.expect_value(t, len(changed), 1)
	if len(changed) == 1 do testing.expect_value(t, changed[0], "web")
	// a session file's new stamp (web_view_tick's read) is a change even with the sections alike
	state.open_sessions[0].mtime._nsec = 1_700_000_000_000_000_000
	_ = web_view_cached(secs2[:])
	testing.expect_value(t, web_view_last.builds, n + 2)

	// web_watch: a browser's only
	r := run_command(Web_Watch{projects = {p.id}}, Caller{kind = .UI})
	testing.expect(t, !r.ok && r.error != "", "refused for the window")
	state = State{}
}

// The New session picker's choices a browser gets ("web".new): the native picker's
// (new_session_choices) per machine and kind of project, one row per harness, the last used first;
// a change of what is installed computes the section again.
@(test)
web_view_new_choices_section :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	// never the developer's own Claude or Codex folders
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	home := fmt.tprintf("%s/deckhand-web-new-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(home)
	defer os.remove_all(home)
	os.set_env("HOME", home)
	os.unset_env("CLAUDE_CONFIG_DIR")
	pi_installed_probe = proc() -> bool {return true}
	claude_installed_probe = proc() -> bool {return true}
	codex_installed_probe = proc() -> bool {return false}
	defer pi_installed_probe, claude_installed_probe, codex_installed_probe = nil, nil, nil
	state.settings.last_harness = .Claude
	checks := []Machine_Check{{id = "pi", state = .Ok}, {id = "claude", state = .Too_Old}, {id = "codex", state = .Ok}}
	machines := []Machine_View{{no = 2, name = "m2", checklist = checks, codex = true}, {no = 3, name = "m3", checklist = checks[2:]}}
	state.machines = machines

	new_of :: proc() -> string {
		secs := state_sections(&state)
		for x in web_view_cached(secs[:]) do if x[0] == "web" {
			v, err := json.parse_string(x[1], allocator = context.temp_allocator)
			if err != nil do return "bad json"
			b := strings.builder_make(context.temp_allocator)
			for m in v.(json.Object)["new"].(json.Array) {
				o := m.(json.Object)
				fmt.sbprintf(&b, "%d:", int(o["machine"].(json.Float)))
				for kind in ([]string{"projects", "chats"}) {
					strings.write_string(&b, " ")
					for c, i in o[kind].(json.Array) {
						if i > 0 do strings.write_byte(&b, ',')
						fmt.sbprintf(&b, "%s=%s", c.(json.Object)["harness"].(json.String), c.(json.Object)["label"].(json.String))
					}
					strings.write_string(&b, " |")
				}
				if strings.contains(o["note"].(json.String), "Codex") do strings.write_string(&b, " (codex note)")
				strings.write_byte(&b, '\n')
			}
			return strings.to_string(b)
		}
		return "no web section"
	}
	// here: Claude Code first (the last used), in Chats too; m2: Codex while its core starts it, never
	// Claude Code or Codex in its Chats; m3: Codex there but its core too old: none, and why
	testing.expect_value(t, new_of(), "0: claude=Claude Code,pi=pi | claude=Claude Code,pi=pi |\n2: claude=Claude Code,pi=pi,codex=Codex | pi=pi |\n3:  |  | (codex note)\n")
	// Codex installed here (no other section changes): offered at once, in Chats too
	codex_installed_probe = proc() -> bool {return true}
	testing.expect(t, strings.has_prefix(new_of(), "0: claude=Claude Code,pi=pi,codex=Codex | claude=Claude Code,pi=pi,codex=Codex |\n"), new_of())
	pi_installed_probe = proc() -> bool {return false}
	testing.expect(t, strings.has_prefix(new_of(), "0: claude=Claude Code,codex=Codex | claude=Claude Code,codex=Codex |\n"), new_of())
}
