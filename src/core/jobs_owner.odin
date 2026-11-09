package core

// Who a job belongs to (the Jobs tab's groups, job_list's `owner`): one of
// the user's projects, Atlas, Chats or Other. Display only: the owner never
// changes where or how a job runs (its `folder:` does that).
//
//   1. `for_project:` decides when it is set:
//      - `atlas`, `chats`, `none` (any case): Atlas, Chats, Other;
//      - a path (`/…` or `~/…`): the listed project with exactly that
//        folder (hidden ones too: the note named it);
//      - else a name: the project whose name (its rename, else the name the
//        sidebar shows, else its folder's name) is that, ignoring case. Two
//        projects with that name: no match (the note should give a path).
//      A value that matches no project is kept as `unmatched` (the row says
//      so) and the folder decides, as if it were not set.
//   2. Else `folder:` decides, by the projects tree's rule (path_within:
//      whole path components): the deepest of the listed projects that are
//      shown (hidden ones are skipped; the home folder and / only for a job
//      in exactly that folder, never as a container), Atlas's folder
//      (folder_of(.Atlas)) and the chats folder (folder_of(.Chats)). On a
//      tie Atlas or Chats wins over a project.
//   3. Else Other.
//
// New job's picker and job_create write a project as its folder path
// (`~/…`): a path survives renames and two projects with one folder name;
// a name is accepted for hand-written notes.

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Job_Owner_Kind :: enum u8 {
	Project,
	Atlas,
	Chats,
	Other,
}
JOB_OWNER_NAMES := [Job_Owner_Kind]string {
	.Project = "project",
	.Atlas   = "atlas",
	.Chats   = "chats",
	.Other   = "other",
}

Job_Owner :: struct {
	kind:      Job_Owner_Kind,
	project:   u64, // .Project: its id
	path:      string, // .Project: its folder
	name:      string, // .Project: its name as the sidebar shows it
	unmatched: string, // for_project named no listed project: the folder decided
	ambiguous: bool, // unmatched because several projects have that name
}

// A project as the owner rules see it.
Owner_Project :: struct {
	id:     u64,
	cwd:    string,
	name:   string, // the user's rename ("" = none)
	shown:  string, // the name the sidebar shows (project_display)
	hidden: bool, // hidden in the Projects list (by the user, temp or missing)
}

// The listed projects (not Chats), for job_owner_resolve (temp allocator).
owner_projects :: proc() -> []Owner_Project {
	out := make([dynamic]Owner_Project, context.temp_allocator)
	for p in state.projects {
		if p.group != .Projects || p.machine != 0 do continue // jobs run on this Mac
		append(&out, Owner_Project{id = p.id, cwd = p.cwd, name = p.name, shown = project_display(p), hidden = project_hide_reason(p) != .None})
	}
	return out[:]
}

// `~/x` → `$HOME/x`; trailing slashes go (temp allocator).
owner_expand :: proc(p: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	s := p
	if s == "~" do s = home
	else if strings.has_prefix(s, "~/") do s = strings.concatenate({home, s[1:]}, context.temp_allocator)
	t := strings.trim_right(s, "/")
	return t == "" && strings.has_prefix(s, "/") ? "/" : t
}

// A path as `~/…` when it is in the home folder (whole components; temp).
path_tilde :: proc(p: string) -> string {
	home := strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")
	if home == "" || !path_within(p, home) do return p
	if len(p) == len(home) do return "~"
	return strings.concatenate({"~", p[len(home):]}, context.temp_allocator)
}

// The project a for_project value names (a path or a name), or nil; why
// it matched none ("" = matched).
owner_project_named :: proc(value: string, projects: []Owner_Project) -> (^Owner_Project, string) {
	v := strings.trim_space(value)
	if strings.has_prefix(v, "/") || v == "~" || strings.has_prefix(v, "~/") {
		path := owner_expand(v)
		for &p in projects do if p.cwd == path do return &p, ""
		return nil, "no listed project has this folder"
	}
	found: ^Owner_Project
	n := 0
	for &p in projects {
		if !(strings.equal_fold(p.name, v) || (p.name == "" && strings.equal_fold(p.shown, v)) || strings.equal_fold(filepath.base(p.cwd), v)) do continue
		n += 1
		found = &p
	}
	switch n {
	case 0: return nil, "no listed project has this name"
	case 1: return found, ""
	}
	return nil, "several projects have this name (use the folder)"
}

// The row's warning about for_project ("" = none).
job_owner_warning :: proc(o: Job_Owner) -> string {
	if o.unmatched == "" do return ""
	if o.ambiguous do return fmt.tprintf("⚠ for_project: several projects are named %s (use the folder); grouped by its folder", o.unmatched)
	return fmt.tprintf("⚠ for_project: %s is not one of your projects; grouped by its folder", o.unmatched)
}

// The owner of a job with these settings. folder: absolute (Job_Def.folder).
job_owner_resolve :: proc(for_project, folder: string, projects: []Owner_Project, atlas_dir, chats_dir: string) -> (o: Job_Owner) {
	fp := strings.trim_space(for_project)
	if fp != "" {
		switch strings.to_lower(fp, context.temp_allocator) {
		case "atlas": return {kind = .Atlas}
		case "chats": return {kind = .Chats}
		case "none":  return {kind = .Other}
		}
		p, why := owner_project_named(fp, projects)
		if p != nil do return {kind = .Project, project = p.id, path = p.cwd, name = p.shown}
		o.unmatched = fp
		o.ambiguous = strings.has_prefix(why, "several")
	}
	home := strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")
	best := -1
	o.kind = .Other
	for p in projects {
		if p.hidden || p.cwd == "" do continue
		container := p.cwd != "/" && p.cwd != home
		if !(folder == p.cwd || (container && path_within(folder, p.cwd))) do continue
		if len(p.cwd) <= best do continue
		best = len(p.cwd)
		o.kind, o.project, o.path, o.name = .Project, p.id, p.cwd, p.shown
	}
	special := [2]struct {
		dir:  string,
		kind: Job_Owner_Kind,
	}{{owner_expand(atlas_dir), .Atlas}, {owner_expand(chats_dir), .Chats}}
	for sp in special {
		if sp.dir == "" || !path_within(folder, sp.dir) || len(sp.dir) < best do continue
		best = len(sp.dir)
		o.kind, o.project, o.path, o.name = sp.kind, 0, "", ""
	}
	return
}

// A job row's owner now (from the projects Deckhand lists now).
job_owner_of :: proc(r: Job_Row, projects: []Owner_Project) -> Job_Owner {
	return job_owner_resolve(r.project, r.folder, projects, folder_of(.Atlas), folder_of(.Chats))
}

// A group's label: the project's name, Atlas's name, "Chats", "Other".
job_owner_label :: proc(o: Job_Owner) -> string {
	switch o.kind {
	case .Project: return o.name
	case .Atlas:   return agent_name()
	case .Chats:   return "Chats"
	case .Other:   return "Other"
	}
	return ""
}

// A group's stable key (fold state): "project:<folder>", "atlas", "chats", "other".
job_owner_key :: proc(o: Job_Owner) -> string {
	if o.kind == .Project do return strings.concatenate({"project:", o.path}, context.temp_allocator)
	return JOB_OWNER_NAMES[o.kind]
}

// The Jobs tab's groups: projects by name, then Atlas, Chats, Other; each
// with its rows (indices into state.jobs, in their order). Temp allocator.
Job_Group :: struct {
	owner: Job_Owner,
	rows:  [dynamic]int,
}

// The groups, worked out again only when State changed or a row's owner
// settings did (the Jobs tab asks every frame). Valid until the next call.
@(private = "file")
groups_cache: struct {
	version: u64,
	key:     u64, // the rows' ids, for_project and folder
	arena:   virtual.Arena, // the groups and their strings
	groups:  []Job_Group,
	built:   bool,
}

jobs_groups :: proc() -> []Job_Group {
	c := &groups_cache
	h: u64 = 14695981039346656037
	mix :: proc(h: ^u64, s: string) {
		for b in transmute([]u8)s do h^ = (h^ ~ u64(b)) * 1099511628211
		h^ = (h^ ~ 0xff) * 1099511628211
	}
	for r in state.jobs {
		mix(&h, r.id)
		mix(&h, r.project)
		mix(&h, r.folder)
	}
	if c.built && c.version == state.version && c.key == h do return c.groups
	virtual.arena_destroy(&c.arena)
	c^ = {version = state.version, key = h, built = true}
	alloc := virtual.arena_allocator(&c.arena)
	projects := owner_projects()
	groups := make([dynamic]Job_Group, alloc)
	for r, i in state.jobs {
		o := job_owner_of(r, projects)
		at := -1
		for g, j in groups do if g.owner.kind == o.kind && g.owner.project == o.project do at = j
		if at < 0 {
			append(&groups, Job_Group{owner = {kind = o.kind, project = o.project, path = strings.clone(o.path, alloc), name = strings.clone(o.name, alloc)}, rows = make([dynamic]int, alloc)})
			at = len(groups) - 1
		}
		append(&groups[at].rows, i)
	}
	slice.sort_by(groups[:], proc(a, b: Job_Group) -> bool {
		if a.owner.kind != b.owner.kind do return a.owner.kind < b.owner.kind
		la, lb := strings.to_lower(a.owner.name, context.temp_allocator), strings.to_lower(b.owner.name, context.temp_allocator)
		if la != lb do return la < lb
		return a.owner.path < b.owner.path
	})
	c.groups = groups[:]
	return c.groups
}

// What New job writes for an owner: the for_project value and the folder
// (job_create). value: a project (its folder or name), atlas, chats or
// none; "" = neither (the old behaviour). err: why it cannot.
job_owner_for_create :: proc(value: string) -> (for_project, folder, err: string) {
	v := strings.trim_space(value)
	switch strings.to_lower(v, context.temp_allocator) {
	case "":      return "", "", ""
	case "atlas":
		d := folder_of(.Atlas)
		if d == "" do return "", "", "for_project: atlas needs a main folder (Atlas's folder is in it)"
		return "atlas", path_tilde(d), ""
	case "chats": return "chats", path_tilde(folder_of(.Chats)), ""
	case "none":  return "none", "~", ""
	}
	p, why := owner_project_named(v, owner_projects())
	if p == nil do return "", "", strings.concatenate({"for_project: ", why, " (a project's folder or name, or atlas, chats, none)"}, context.temp_allocator)
	t := path_tilde(p.cwd)
	return t, t, ""
}
