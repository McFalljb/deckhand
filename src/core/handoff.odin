package core

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

// "New session on <machine>…" (docs/GUIDE.md, Other machines): this Mac's project, and the
// projects of the same name on the machines online now. Choosing one does what that project's
// "+ New session" does there (ui_handoff.odin): a fresh session on that machine. Nothing of this
// Mac's crosses: no path, account, conversation or git state; only the remote project's packed id.

HANDOFF_PER_MACHINE :: 3 // rows per machine, then "and N more on <machine>"
HANDOFF_MAX :: 8 // rows in all
HANDOFF_FOLDER_RUNES :: 40 // a folder shown longer than this is cut in its middle
HANDOFF_NAME_RUNES :: 32

// A project on another machine that matches one here, as its row shows it: its packed id, its
// machine, that machine's core run and the project's folder when the row was made (what a click
// checks again: ui_handoff.odin), and the row's label ("New session on nuc in api", "… (~/work/api)"
// when that machine has several). project_id 0: a plain-text row ("and 4 more on box") (temp).
Handoff_Target :: struct {
	project_id: u64,
	machine:    u64,
	run:        string,
	folder:     string,
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
// At most HANDOFF_PER_MACHINE rows per machine and HANDOFF_MAX in all; a machine's others are
// one plain-text row. Empty: none, or pid is not this Mac's project (temp).
handoff_targets :: proc(pid: u64) -> []Handoff_Target {
	out := make([dynamic]Handoff_Target, context.temp_allocator)
	if !machines_in_sidebar() || id_machine(pid) != 0 do return out[:]
	p := find_project(pid)
	if p == nil || p.machine != 0 || p.group != .Projects do return out[:]
	name := handoff_name(p.cwd)
	if name == "" do return out[:]
	rows := 0
	for m in state.machines {
		if m.status != .Online do continue
		found := make([dynamic]^Project, context.temp_allocator)
		for &rp in state.projects {
			if rp.machine != m.no || id_machine(rp.id) != m.no || rp.group != .Projects do continue
			if handoff_name(rp.cwd) == name do append(&found, &rp)
		}
		take := min(len(found), HANDOFF_PER_MACHINE, HANDOFF_MAX - rows)
		user := handoff_user(m.target)
		for rp in found[:take] {
			label := fmt.tprintf("New session on %s in %s", m.name, clip_middle(name, HANDOFF_NAME_RUNES))
			// several on that machine: each with its folder there
			if len(found) > 1 do label = fmt.tprintf("%s (%s)", label, clip_middle(handoff_short(rp.cwd, user), HANDOFF_FOLDER_RUNES))
			append(&out, Handoff_Target{project_id = rp.id, machine = m.no, run = m.core_run, folder = rp.cwd, label = label})
		}
		rows += take
		if len(found) > take do append(&out, Handoff_Target{machine = m.no, label = fmt.tprintf("and %d more on %s", len(found) - take, m.name)})
	}
	return out[:]
}

// The user a machine's link logs in as, when its target says ("jb@nuc": "jb"); "" = not known
// (a name from ~/.ssh/config).
handoff_user :: proc(target: string) -> string {
	i := strings.last_index_byte(target, '@')
	return i > 0 ? target[:i] : ""
}

// Another machine's folder, shorter: the home of user (the one its link logs in as) as "~"
// (/home/<user>, /Users/<user>, /root for root); anything else, and every folder while user is
// not known, as it is (cleaned already) (temp).
handoff_short :: proc(cwd: string, user := "") -> string {
	if user == "" || strings.contains_rune(user, '/') do return cwd
	homes := user == "root" ? []string{"/root"} : []string{fmt.tprintf("/home/%s", user), fmt.tprintf("/Users/%s", user)}
	for home in homes {
		if cwd == home do return "~"
		if strings.has_prefix(cwd, home) && cwd[len(home)] == '/' do return fmt.tprintf("~%s", cwd[len(home):])
	}
	return cwd
}

// s cut to at most max runes in its middle ("/srv/deep/…/end/api"), both ends kept (temp).
clip_middle :: proc(s: string, max: int) -> string {
	n := utf8.rune_count_in_string(s)
	if n <= max || max < 3 do return s
	keep := max - 1
	head, tail := (keep + 1) / 2, keep / 2
	runes := utf8.string_to_runes(s, context.temp_allocator)
	return fmt.tprintf("%s…%s", utf8.runes_to_string(runes[:head], context.temp_allocator), utf8.runes_to_string(runes[n - tail:], context.temp_allocator))
}
