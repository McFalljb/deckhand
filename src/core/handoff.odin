package core

import "core:fmt"
import "core:path/filepath"
import "core:strings"

// "New session on <machine>…" (docs/GUIDE.md, Other machines): this Mac's project, and the
// projects of the same name on the machines online now. Choosing one does what that project's
// "+ New session" does there (ui_handoff.odin): a fresh session on that machine. Nothing of this
// Mac's crosses: no path, account, conversation or git state; only the remote project's packed id.

// A project on another machine that matches one here: its packed id and the menu row's label
// ("New session on nuc in api", "… (~/work/api)" when that machine has several) (temp).
Handoff_Target :: struct {
	project_id: u64,
	label:      string,
}

// The folder name a project matches by: the last component of its folder (another machine's as
// the mirror cleaned it, text_clean_remote). "" = none to match ("/", ".", nothing).
handoff_name :: proc(cwd: string) -> string {
	if cwd == "" do return ""
	b := filepath.base(cwd)
	if b == "/" || b == "." || b == ".." do return ""
	return b
}

// This Mac's project pid's matches: for each machine online now (its order), its projects whose
// folder name equals this one's, case-sensitively (no fuzzy match, no git remote: not mirrored).
// Empty: none, or pid is not this Mac's project (temp).
handoff_targets :: proc(pid: u64) -> []Handoff_Target {
	out := make([dynamic]Handoff_Target, context.temp_allocator)
	if !machines_in_sidebar() || id_machine(pid) != 0 do return out[:]
	p := find_project(pid)
	if p == nil || p.machine != 0 || p.group != .Projects do return out[:]
	name := handoff_name(p.cwd)
	if name == "" do return out[:]
	for m in state.machines {
		if m.status != .Online do continue
		start := len(out)
		for &rp in state.projects {
			if rp.machine != m.no || id_machine(rp.id) != m.no || rp.group != .Projects do continue
			if handoff_name(rp.cwd) != name do continue
			append(&out, Handoff_Target{project_id = rp.id, label = fmt.tprintf("New session on %s in %s", m.name, name)})
		}
		// several on that machine: each with its folder there
		if len(out) - start > 1 do for &t in out[start:] {
			rp := find_project(t.project_id)
			t.label = fmt.tprintf("%s (%s)", t.label, handoff_short(rp.cwd))
		}
	}
	return out[:]
}

// Another machine's folder, shorter: its home as "~" (/home/<user>, /Users/<user>, /root); else
// as it is (cleaned already) (temp).
handoff_short :: proc(cwd: string) -> string {
	if cwd == "/root" || strings.has_prefix(cwd, "/root/") do return fmt.tprintf("~%s", cwd[len("/root"):])
	for home in ([]string{"/home/", "/Users/"}) do if strings.has_prefix(cwd, home) {
		rest := cwd[len(home):]
		if rest == "" do break
		i := strings.index_byte(rest, '/')
		if i < 0 do return "~"
		return fmt.tprintf("~%s", rest[i:])
	}
	return cwd
}
