package main

// The harness manifest (docs/HARNESSES.md §6, §7): one row per item a harness needs or Deckhand
// recommends with it, read by the setup sheet's checklist (ui_harness.odin) and the Settings tab's
// Coding agents group. A new harness adds rows here (and its Harness value), not code paths.
//
//   - kind: the harness itself, Deckhand's own integration (ships in the app: "built in", never
//     installed), or a third-party item (installed by the matching package manager on a click).
//   - need: Required or Recommended. A harness is required for its own tabs only: a user with one
//     harness sees the other collapsed ("Not installed — Install").
//   - detect: how it is found, always by looking (stat, reading a package.json or pi's
//     settings.json), never by running anything. Setup only reads the user's harness config.
//   - install: the official install command, run only after a click, in the checklist's visible
//     terminal (harness_install.odin), and only when the item is not found: never a second copy.
//   - update: per install layout (where the binary links to). Brew, npm, bun, pnpm and the
//     managed/native install run after a click; nix, mise and anything unknown are shown only.
//
// Rows and their sources are listed in docs/HARNESSES.md §6.

import "core:encoding/json"
import jg "jsonguard"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

Harness_Item_Kind :: enum u8 {
	Harness, // the harness itself (third-party, installed by the user's click)
	Built_In, // Deckhand's own integration: ships in the app, nothing to install
	Third_Party, // someone else's package, installed by the harness's package manager on a click
}

Harness_Need :: enum u8 {
	Required,
	Recommended,
}

// How an item is found (never run).
Harness_Detect :: enum u8 {
	Binary, // the harness's binary: on the PATH new tabs get and its install folders
	Integration, // Deckhand's bundled integration for the harness (pi: integrations/pi; Claude: the plugin)
	Pi_Package, // a pi package in ~/.pi/agent/settings.json `packages` (detect_arg: the npm name)
}

// Where a harness's binary links to decides how it updates.
Install_Layout :: enum u8 {
	Unknown,
	Managed, // the official installer's own layout (pi: ~/.pi/agent; Claude: …/claude/versions/)
	Brew, // Homebrew's Caskroom or Cellar
	Npm, // a global npm install (Homebrew's node too)
	Bun,
	Pnpm,
	Yarn,
	Nix,
	Mise,
}

INSTALL_LAYOUT_NAMES := [Install_Layout]string {
	.Unknown = "unknown layout",
	.Managed = "official installer",
	.Brew    = "Homebrew",
	.Npm     = "npm",
	.Bun     = "bun",
	.Pnpm    = "pnpm",
	.Yarn    = "yarn",
	.Nix     = "nix",
	.Mise    = "mise",
}

// The layouts whose update runs after a click (the user's rule, docs/HARNESSES.md §7). The rest are
// shown only: nix and mise updates belong to the user's own configuration; an unknown layout may be
// a wrapper Deckhand cannot see through.
HARNESS_RUNNABLE_LAYOUTS :: bit_set[Install_Layout]{.Managed, .Brew, .Npm, .Bun, .Pnpm}

Harness_Row :: struct {
	harness:     Harness,
	id:          string, // stable: the state snapshot, Settings rows, the runner
	name:        string,
	kind:        Harness_Item_Kind,
	need:        Harness_Need,
	min_version: string, // "" = any
	detect:      Harness_Detect,
	detect_arg:  string, // Pi_Package: the npm package name
	install:     string, // the command when missing ("" = nothing to install: built in)
	update:      [Install_Layout]string, // per layout ("" = the package manager's own way, unnamed)
	update_any:  string, // a third-party item: its update, whatever the harness's layout
	// Commands are templates (harness_plan): {bin} is the binary Deckhand detected, {pi} the pi it
	// detected, {pm} the package manager next to the detected install's prefix and {prefix} that
	// prefix, each by absolute path: a login shell's PATH (path_helper, a .zprofile) may find
	// another copy.
	why:         string, // one line: why it is needed or recommended
	source:      string, // where the install command comes from
}

// The rows, harness by harness, the harness first. Real items only: pi's two recommended packages
// feed the bundled `panels` extension's Subagents and Todos panels (integrations/pi/extensions/
// panels), vetted and pinned by pi-kit (packages.json, test/ci/package.json). Claude Code needs
// nothing third-party: its plugin is sh and Deckhand's own CLI.
HARNESS_MANIFEST := [?]Harness_Row {
	{
		harness = .Pi, id = "pi", name = "pi", kind = .Harness, need = .Required, min_version = PI_MIN_VERSION, detect = .Binary,
		install = PI_INSTALL_COMMAND,
		update = {.Unknown = PI_SELF_UPDATE, .Managed = PI_SELF_UPDATE, .Brew = "", .Npm = PI_SELF_UPDATE, .Bun = PI_SELF_UPDATE, .Pnpm = PI_SELF_UPDATE, .Yarn = PI_SELF_UPDATE, .Nix = "nix profile upgrade pi", .Mise = ""},
		why = "Runs pi tabs, Atlas and jobs",
		source = "https://github.com/earendil-works/pi#getting-started (README: Getting started; docs/quickstart.md, docs/cli.md `pi update`)",
	},
	{
		harness = .Pi, id = "pi-integration", name = "Deckhand's pi integration", kind = .Built_In, need = .Required, detect = .Integration,
		why = "Status, waits, comments, panels, Atlas's and the browser tools in pi tabs (loaded with `pi -e`)",
		source = "integrations/pi (ships in Deckhand.app)",
	},
	{
		harness = .Pi, id = "pi-subagents", name = "pi-subagents", kind = .Third_Party, need = .Recommended, min_version = "0.84.0", detect = .Pi_Package, detect_arg = "pi-subagents",
		install = "{pi} install npm:pi-subagents@0.84.0", update_any = "{pi} install npm:pi-subagents@0.84.0",
		why = "Background workers and reviewers; feeds the Subagents panel (0.84.0 fixes GHSA-6v8j-6w28-2w8r)",
		source = "https://www.npmjs.com/package/pi-subagents (pin: pi-kit test/ci/package.json; `pi install`: pi docs/cli.md)",
	},
	{
		harness = .Pi, id = "rpiv-todo", name = "rpiv-todo", kind = .Third_Party, need = .Recommended, detect = .Pi_Package, detect_arg = "@juicesharp/rpiv-todo",
		install = "{pi} install npm:@juicesharp/rpiv-todo@2.15.0",
		why = "A todo tool and /todos; feeds the Todos panel",
		source = "https://www.npmjs.com/package/@juicesharp/rpiv-todo (pin: pi-kit test/ci/package.json)",
	},
	{
		harness = .Claude, id = "claude", name = "Claude Code", kind = .Harness, need = .Required, min_version = CLAUDE_MIN_VERSION, detect = .Binary,
		install = CLAUDE_INSTALL_COMMAND,
		update = {.Unknown = "{bin} update", .Managed = "{bin} update", .Brew = "{pm} upgrade --cask claude-code", .Npm = "{pm} install -g --prefix {prefix} @anthropic-ai/claude-code@latest", .Bun = "{pm} add -g @anthropic-ai/claude-code@latest", .Pnpm = "{pm} add -g @anthropic-ai/claude-code@latest", .Yarn = "", .Nix = "", .Mise = ""},
		why = "Runs Claude tabs and sessions",
		source = "https://code.claude.com/docs/en/setup (Install Claude Code; Update Claude Code; Install with npm)",
	},
	{
		harness = .Claude, id = "claude-plugin", name = "Deckhand's Claude Code plugin", kind = .Built_In, need = .Required, detect = .Integration,
		why = "Session ids, comments, held messages, panels and the read-only guard in Claude tabs (loaded with --plugin-dir)",
		source = "integrations/claude-code (ships in Deckhand.app)",
	},
}

// pi's official installer (README "Getting started"; it pins pi's dependencies and installs Node
// when needed). npm needs Node 22.19 or later first, so the installer is the one offered.
PI_INSTALL_COMMAND :: "curl --proto '=https' --proto-redir '=https' -fsSL https://pi.dev/install.sh | sh"
// pi updates itself for its own installer, npm, bun, pnpm and yarn (`--self`: pi only, not packages).
PI_SELF_UPDATE :: "{bin} update --self"
// Claude Code's native installer (code.claude.com/docs/en/setup, "Native Install (Recommended)").
CLAUDE_INSTALL_COMMAND :: "curl --proto '=https' --proto-redir '=https' -fsSL https://claude.ai/install.sh | bash"

harness_row :: proc(id: string) -> (Harness_Row, bool) {
	for r in HARNESS_MANIFEST do if r.id == id do return r, true
	return {}, false
}

// ---- layouts ----

// The layout of a harness binary from where it really is (links resolved). pi's own installer lives
// in pi's agent folder (agent_dir); Claude Code's native installer keeps …/claude/versions/<v>.
install_layout :: proc(h: Harness, real, agent_dir: string) -> Install_Layout {
	switch {
	case strings.contains(real, "/nix/store/"):                                                  return .Nix
	case strings.contains(real, "/mise/installs/"):                                              return .Mise
	case strings.contains(real, "/Caskroom/") || strings.contains(real, "/Cellar/"):             return .Brew
	case strings.contains(real, "/.bun/") || strings.contains(real, "/install/global/node_modules/"): return .Bun
	case strings.contains(real, "/pnpm/") || strings.contains(real, "/.pnpm/"):                   return .Pnpm
	case strings.contains(real, "/yarn/") || strings.contains(real, "/.yarn/"):                   return .Yarn
	}
	switch h {
	case .Pi:
		ad := strings.trim_right(agent_dir, "/")
		if ad != "" && strings.has_prefix(real, strings.concatenate({ad, "/"}, context.temp_allocator)) do return .Managed
		if strings.contains(real, "/node_modules/") do return .Npm
	case .Claude:
		if strings.contains(real, "/claude/versions/") do return .Managed
		if strings.contains(real, "/node_modules/") do return .Npm
	}
	return .Unknown
}

// What an action runs, with the detected paths filled in (harness_plan).
Harness_Plan :: struct {
	command:  string, // shown, and run when runnable ("" = none to name)
	runnable: bool,
	pm:       string, // the package manager the command or the harness's self-update uses ("" = none)
	path_dir: string, // put first on the run's PATH: the folder of pm (its node, for npm)
	note:     string, // why it is not runnable ("" = it is, or nothing to say)
}

// A word for sh: as it is when it is plain, else in single quotes (temp).
sh_word :: proc(s: string) -> string {
	if s == "" do return "''"
	for c in transmute([]u8)s do if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.index_byte("/._-+:@=%,", c) >= 0) do return sh_quote(s)
	return s
}

// The package manager that owns an install, found next to its prefix (never on PATH): Homebrew's
// brew in <prefix>/bin, npm in <prefix>/bin for <prefix>/lib/node_modules, bun in <root>/bin for
// <root>/install/global/node_modules, pnpm in PNPM_HOME (the folder holding global/ or its shims).
// pm "" = none found there; prefix: what it installs into.
harness_package_manager :: proc(layout: Install_Layout, bin, real: string) -> (pm, prefix: string) {
	exe :: proc(p: string) -> bool {return exe_in(filepath.dir(p), filepath.base(p))}
	try :: proc(dir, name: string) -> string {
		p := fmt.tprintf("%s/%s", dir, name)
		return exe(p) ? p : ""
	}
	#partial switch layout {
	case .Brew:
		for m in ([]string{"/Caskroom/", "/Cellar/"}) do if i := strings.index(real, m); i > 0 do return try(fmt.tprintf("%s/bin", real[:i]), "brew"), real[:i]
	case .Npm:
		if i := strings.last_index(real, "/lib/node_modules/"); i > 0 do return try(fmt.tprintf("%s/bin", real[:i]), "npm"), real[:i]
	case .Bun:
		if i := strings.last_index(real, "/install/global/node_modules/"); i > 0 do return try(fmt.tprintf("%s/bin", real[:i]), "bun"), real[:i]
	case .Pnpm:
		home := ""
		if i := strings.last_index(real, "/global/"); i > 0 do home = real[:i]
		else if bin != "" do home = filepath.dir(bin) // a shim in PNPM_HOME
		if home != "" do return try(home, "pnpm"), home
	}
	return "", ""
}

// The command for row r's action on this install: its template with the detected binary (bin; real:
// where it links to), the package manager next to its prefix and that prefix, by absolute path. Not
// runnable: a layout Deckhand shows only (nix, mise, yarn, unknown), no binary detected, no package
// manager found next to the prefix, or a prefix it could not write without sudo.
// pi_bin: the pi detected (a third-party pi package's commands run it).
harness_plan :: proc(r: Harness_Row, action: Harness_Action, layout: Install_Layout, bin, real: string, pi_bin := "") -> Harness_Plan {
	p: Harness_Plan
	tmpl := ""
	switch {
	case action == .Install:
		tmpl = r.install
	case r.kind == .Third_Party:
		tmpl = r.update_any != "" ? r.update_any : r.install
	case:
		tmpl = r.update[layout]
		if r.harness == .Pi && layout == .Brew do tmpl = "" // no pi formula is known: Homebrew's own way
		if r.harness == .Claude && layout == .Brew && strings.contains(real, "/Caskroom/claude-code@latest/") do tmpl, _ = strings.replace_all(tmpl, "claude-code", "claude-code@latest", context.temp_allocator)
	}
	if tmpl == "" do return p
	pm, prefix := harness_package_manager(layout, bin, real)
	names := [Install_Layout]string{.Unknown = "", .Managed = "", .Brew = "brew", .Npm = "npm", .Bun = "bun", .Pnpm = "pnpm", .Yarn = "yarn", .Nix = "", .Mise = ""}
	// one pass over the template: a value is never read again (a path holding "{pm}" stays itself)
	vals := [?][2]string {
		{"{bin}", bin != "" ? sh_word(bin) : HARNESS_BIN_NAMES[r.harness]},
		{"{pi}", pi_bin != "" ? sh_word(pi_bin) : "pi"},
		{"{pm}", pm != "" ? sh_word(pm) : names[layout]},
		{"{prefix}", prefix != "" ? sh_word(prefix) : "PREFIX"}, // never "<prefix>": a redirect when pasted
	}
	b := strings.builder_make(context.temp_allocator)
	outer: for i := 0; i < len(tmpl); {
		for v in vals do if strings.has_prefix(tmpl[i:], v[0]) {
			strings.write_string(&b, v[1])
			i += len(v[0])
			continue outer
		}
		strings.write_byte(&b, tmpl[i])
		i += 1
	}
	p.command = strings.to_string(b)
	cmd := p.command
	if pm != "" do p.pm, p.path_dir = pm, filepath.dir(pm)
	if action == .Install && r.kind == .Harness {
		p.runnable = true // an official installer: nothing to aim at
		return p
	}
	if r.kind == .Third_Party {
		// pi installs the package into its own folder; the pi Deckhand detected runs it
		p.runnable = pi_bin != ""
		if !p.runnable do p.note = "Deckhand found pi through your shell only: run this yourself"
		return p
	}
	switch {
	case !(layout in HARNESS_RUNNABLE_LAYOUTS):
		p.note = strings.contains(tmpl, "{") || cmd != "" ? fmt.tprintf("Installed with %s: update it there", INSTALL_LAYOUT_NAMES[layout]) : ""
		if layout == .Unknown do p.note = "Deckhand can't tell how this copy was installed: update it the way you installed it"
	case bin == "":
		p.note = "Deckhand found it through your shell only: run this yourself"
	case layout in bit_set[Install_Layout]{.Npm, .Bun, .Pnpm, .Brew} && pm == "":
		p.note = fmt.tprintf("Deckhand found no %s next to this copy (%s): update it yourself", names[layout], prefix != "" ? fs_display(prefix) : fs_display(real))
	case layout == .Npm && !(writable(fmt.tprintf("%s/lib/node_modules", prefix)) && writable(fmt.tprintf("%s/bin", prefix))):
		p.note = "Its npm folder needs sudo, which Deckhand never runs: update it yourself"
	case:
		p.runnable = true
	}
	return p
}

@(private = "file")
writable :: proc(dir: string) -> bool {
	return posix.access(strings.clone_to_cstring(dir, context.temp_allocator), {.W_OK}) == .OK
}

// The update command for the version bar (claude_update_command): the template with bare names, the
// way a user types it ("" = none to name).
harness_update_bare :: proc(r: Harness_Row, layout: Install_Layout, real: string) -> string {
	tmpl := r.update[layout]
	if r.harness == .Pi && layout == .Brew do return ""
	if r.harness == .Claude && layout == .Brew && strings.contains(real, "/Caskroom/claude-code@latest/") do tmpl, _ = strings.replace_all(tmpl, "claude-code", "claude-code@latest", context.temp_allocator)
	names := [Install_Layout]string{.Unknown = "", .Managed = "", .Brew = "brew", .Npm = "npm", .Bun = "bun", .Pnpm = "pnpm", .Yarn = "yarn", .Nix = "", .Mise = ""}
	out, _ := strings.replace_all(tmpl, "--prefix {prefix} ", "", context.temp_allocator)
	out, _ = strings.replace_all(out, "{bin}", HARNESS_BIN_NAMES[r.harness], context.temp_allocator)
	out, _ = strings.replace_all(out, "{pm}", names[layout], context.temp_allocator)
	return out
}

// ---- detection (stat and read only) ----

// The harness binary Deckhand would start, by stat: the PATH new tabs get (none in test mode,
// detect_path), then each harness's install folders. "" = not found this way.
harness_binary :: proc(h: Harness) -> string {
	name := h == .Pi ? "pi" : "claude"
	if h == .Claude {
		if b := hook_env(.Claude_Bin); filepath.is_abs(b) do return b
	}
	for d in strings.split(detect_path(), ":", context.temp_allocator) do if exe_in(d, name) do return fmt.tprintf("%s/%s", strings.trim_right(d, "/"), name)
	switch h {
	case .Pi:
		return pi_managed_path()
	case .Claude:
		home := strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")
		if !filepath.is_abs(home) do return ""
		for d in ([]string{".local/bin", ".claude/local"}) {
			dir := fmt.tprintf("%s/%s", home, d)
			if exe_in(dir, name) do return fmt.tprintf("%s/%s", dir, name)
		}
	}
	return ""
}

// A harness binary's version by looking at where it links to ("" = unknown).
harness_version_of :: proc(h: Harness, bin: string) -> string {
	if bin == "" do return ""
	switch h {
	case .Pi:
		if p := pi_package_of(bin); p != "" do return pkg_version(p)
	case .Claude:
		v, _ := claude_version_of(bin)
		return v
	}
	return ""
}

// A pi package as pi's settings list it (read only). pi's own settings.json decides: an npm source
// gives its spec's version and the installed copy's under <agent dir>/npm/node_modules; a git or
// local source of the same name counts as found (another copy would be a second one), its version
// unknown. A project's .pi/settings.json is noted only (a cloned repo's listing never makes a
// package found), its npm version checked against the minimum too.
Pi_Package_Found :: struct {
	listed:       bool, // in pi's own settings.json
	other:        bool, // ... from a git or local source
	spec:         string, // the version in an npm source ("npm:x@1.2.3" -> "1.2.3"; "" = unpinned)
	installed:    string, // the installed package.json's version ("" = not there or unreadable)
	project:      bool, // in the project's .pi/settings.json
	project_spec: string, // ... its npm version ("" = unpinned, or a git or local source)
}

// A source's package name and version: npm:@x/name@1 -> @x/name, 1; git:github.com/x/name@v1,
// https://…/name.git, ../local/name -> name, "".
@(private = "file")
pi_source_name :: proc(src: string) -> (name, ver: string, npm: bool) {
	if strings.has_prefix(src, "npm:") {
		spec := src[4:]
		if at := strings.last_index_byte(spec, '@'); at > 0 do return spec[:at], spec[at + 1:], true
		return spec, "", true
	}
	n := src
	if i := strings.index(n, ":"); i >= 0 && !strings.has_prefix(n, "/") do n = n[i + 1:]
	n = strings.trim_right(n, "/")
	n = filepath.base(n)
	if at := strings.last_index_byte(n, '@'); at > 0 do n = n[:at]
	return strings.trim_suffix(n, ".git"), "", false
}

// Whether a source of that name is the package (an npm name matches exactly; a git or local folder
// by the name without its scope: @juicesharp/rpiv-todo is rpiv-todo).
@(private = "file")
pi_source_is :: proc(src_name: string, npm: bool, name: string) -> bool {
	if npm do return src_name == name
	bare := name
	if i := strings.last_index_byte(name, '/'); i >= 0 do bare = name[i + 1:]
	return src_name == bare || src_name == name
}

@(private = "file")
pi_settings_sources :: proc(path: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if k, st := path_stat(path); k != .File || st.size > 4 << 20 do return out[:]
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return out[:]
	v, jerr := jg.parse(data, .JSON5, true, context.temp_allocator)
	if jerr != nil do return out[:]
	root, _ := v.(json.Object)
	list, _ := root["packages"].(json.Array)
	for it in list {
		#partial switch x in it {
		case json.String: append(&out, string(x))
		case json.Object: if s, ok := x["source"].(json.String); ok do append(&out, string(s))
		}
	}
	return out[:]
}

// project: a project folder whose .pi/settings.json is read too ("" = none).
pi_package_find :: proc(agent_dir, name: string, project := "") -> Pi_Package_Found {
	out: Pi_Package_Found
	ad := strings.trim_right(agent_dir, "/")
	for src in pi_settings_sources(fmt.tprintf("%s/settings.json", ad)) {
		n, ver, npm := pi_source_name(src)
		if !pi_source_is(n, npm, name) do continue
		if npm {
			out.listed, out.other, out.spec = true, false, ver
			break
		}
		out.listed, out.other = true, true // an npm source of the same name, later, wins
	}
	if project != "" {
		for src in pi_settings_sources(fmt.tprintf("%s/.pi/settings.json", strings.trim_right(project, "/"))) {
			n, ver, npm := pi_source_name(src)
			if !pi_source_is(n, npm, name) do continue
			out.project = true
			if npm {
				out.project_spec = ver
				break
			}
		}
	}
	if !out.listed || out.other do return out
	pj := fmt.tprintf("%s/npm/node_modules/%s/package.json", ad, name)
	if path_kind(pj) == .File do out.installed = pkg_version(pj)
	return out
}

// ---- the checklist ----

Harness_Item_State :: enum u8 {
	Missing, // not found: Install (or, for a third-party item, its harness first)
	Too_Old, // found, older than min_version: Update
	Ok, // found, new enough (or its version is unknown)
	Built_In, // ships in Deckhand and loads
	Not_Loaded, // ships in Deckhand but does not load (the harness is too old, or not in this build)
	Needs_Harness, // a third-party item whose harness is not installed
	Unchecked, // found from a git or local source: its version cannot be checked
}

Harness_Action :: enum u8 {
	None,
	Install,
	Update,
}

// One row of the checklist as it is on this machine.
Harness_Item :: struct {
	row:      int, // index into HARNESS_MANIFEST
	state:    Harness_Item_State,
	version:  string, // what was found ("" = unknown)
	where_:   string, // the binary or package found ("" = none)
	layout:   Install_Layout,
	action:   Harness_Action,
	command:  string, // the command the action runs or shows
	runnable: bool, // Deckhand runs it after a click; else shown with Copy
	note:     string, // a short line under the row ("" = none)
	// what a run is tied to (harness_install.odin checks it again before it runs)
	target:      string, // the detected binary the command runs ("" = none: an installer)
	target_real: string, // where it linked to when detected
	path_dir:    string, // put first on the run's PATH ("" = none)
	pm:          string, // the package manager the command runs, checked again before it runs ("" = none)
}

// What the checklist looks at, gathered once (tests fill it by hand).
Harness_Facts :: struct {
	installed: [Harness]bool, // pi_installed / claude_installed (stat, and pi's login-shell answer)
	bin:       [Harness]string, // the binary found by stat ("" = none)
	real:      [Harness]string, // where it links to
	version:   [Harness]string,
	agent_dir: string,
	integration: [Harness]bool, // the bundled integration is in this build
	packages:  map[string]Pi_Package_Found, // pi packages by name (temp)
}

harness_facts_now :: proc() -> Harness_Facts {
	f: Harness_Facts
	f.agent_dir = pi_agent_dir()
	if r := fs_real(f.agent_dir); r != "" do f.agent_dir = r // binaries are compared by their real path
	f.packages = make(map[string]Pi_Package_Found, allocator = context.temp_allocator)
	for h in Harness {
		f.installed[h] = h == .Pi ? pi_installed() : claude_installed()
		b := harness_binary(h)
		f.bin[h] = b
		if b != "" {
			r := fs_real(b)
			f.real[h] = r != "" ? r : b
			f.version[h] = harness_version_of(h, b)
			f.installed[h] = true
		}
	}
	if f.installed[.Pi] && f.version[.Pi] == "" do f.version[.Pi] = state.reload.pi_version // found by the login shell only
	f.integration[.Pi] = pi_integration_dir() != ""
	f.integration[.Claude] = claude_plugin_dir() != ""
	project := settings_project_cwd() // the project on screen's .pi/settings.json too
	for r in HARNESS_MANIFEST do if r.detect == .Pi_Package do f.packages[r.detect_arg] = pi_package_find(f.agent_dir, r.detect_arg, project)
	return f
}

// The checklist for these facts, in the manifest's order (temp-allocated).
harness_checklist :: proc(f: Harness_Facts) -> []Harness_Item {
	out := make([dynamic]Harness_Item, context.temp_allocator)
	for r, i in HARNESS_MANIFEST {
		it := Harness_Item{row = i}
		h := r.harness
		switch r.kind {
		case .Harness:
			if !f.installed[h] {
				it.state, it.action = .Missing, .Install
				p := harness_plan(r, .Install, .Unknown, "", "")
				it.command, it.runnable = p.command, p.runnable
				break
			}
			it.version, it.where_ = f.version[h], f.bin[h]
			it.layout = f.bin[h] != "" ? install_layout(h, f.real[h], f.agent_dir) : .Unknown
			it.state = .Ok
			if r.min_version != "" && claude_version_below(it.version, r.min_version) {
				it.state, it.action = .Too_Old, .Update
				p := harness_plan(r, .Update, it.layout, f.bin[h], f.real[h])
				it.command, it.runnable, it.note, it.path_dir = p.command, p.runnable, p.note, p.path_dir
				if strings.contains(r.update[it.layout], "{pm}") do it.pm = p.pm
				if it.note == "" && !it.runnable do it.note = fmt.tprintf("Installed with %s: update it with that package manager", INSTALL_LAYOUT_NAMES[it.layout])
				it.target, it.target_real = f.bin[h], f.real[h]
			}
		case .Built_In:
			harness_ok := f.installed[h] && !(h == .Pi && harness_old(f, .Pi))
			switch {
			case !f.integration[h]:
				it.state, it.note = .Not_Loaded, "Not in this build of Deckhand"
			case !f.installed[h]:
				it.state = .Built_In
			case !harness_ok:
				it.state, it.note = .Not_Loaded, fmt.tprintf("Not loaded: pi %s is older than %s", f.version[.Pi], PI_MIN_VERSION)
			case:
				it.state = .Built_In
			}
		case .Third_Party:
			if !f.installed[h] || (h == .Pi && harness_old(f, .Pi)) {
				it.state = .Needs_Harness
				break
			}
			pk := f.packages[r.detect_arg]
			pi_layout := f.bin[.Pi] != "" ? install_layout(.Pi, f.real[.Pi], f.agent_dir) : .Unknown
			plan :: proc(it: ^Harness_Item, r: Harness_Row, action: Harness_Action, f: Harness_Facts, layout: Install_Layout) {
				p := harness_plan(r, action, layout, f.bin[.Pi], f.real[.Pi], f.bin[.Pi])
				it.command, it.runnable, it.note = p.command, p.runnable, p.note
				pp := harness_plan(HARNESS_MANIFEST[harness_first_row(.Pi)], .Update, layout, f.bin[.Pi], f.real[.Pi])
				it.path_dir = pp.path_dir // pi runs npm to install: the one next to pi's prefix
				it.target, it.target_real = f.bin[.Pi], f.real[.Pi]
			}
			// a project's listing: a note, and its pin checked too (it never makes the package found)
			project_note := ""
			project_old := pk.project_spec != "" && r.min_version != "" && claude_version_below(pk.project_spec, r.min_version)
			if project_old do project_note = fmt.tprintf("Also listed in this project's settings at %s, older than %s: change it in its .pi/settings.json", pk.project_spec, r.min_version)
			else if pk.project do project_note = "Also listed in this project's settings"
			switch {
			case !pk.listed:
				it.state, it.action = .Missing, .Install
				plan(&it, r, .Install, f, pi_layout)
			case pk.other:
				it.state, it.note = .Unchecked, "Found from a git or local source: Deckhand can't check its version"
			case:
				it.state = .Ok
				it.version = pk.installed != "" ? pk.installed : pk.spec
				if r.min_version != "" && claude_version_below(it.version, r.min_version) {
					it.state, it.action = .Too_Old, .Update
					plan(&it, r, .Update, f, pi_layout)
				}
			}
			if project_old && (it.state == .Ok || it.state == .Unchecked) do it.state, it.version = .Too_Old, pk.project_spec // nothing Deckhand runs: the note says where
			if project_note != "" do it.note = it.note != "" ? fmt.tprintf("%s. %s", it.note, project_note) : project_note
		}
		append(&out, it)
	}
	return out[:]
}

@(private = "file")
harness_old :: proc(f: Harness_Facts, h: Harness) -> bool {
	r := HARNESS_MANIFEST[harness_first_row(h)]
	return r.min_version != "" && claude_version_below(f.version[h], r.min_version)
}

// The harness's own row.
harness_first_row :: proc(h: Harness) -> int {
	for r, i in HARNESS_MANIFEST do if r.harness == h && r.kind == .Harness do return i
	return 0
}

// ---- the cached checklist the UI shows ----

// Looked at again by harness_checklist_refresh (the sheet's step opens, Settings shows it, a run
// ended, the shell environment refreshed); never per frame. Strings live in the arena below.
harness_items: [dynamic]Harness_Item
@(private = "file")
items_strings: [dynamic]string

// Tests: stands in for harness_facts_now.
harness_facts_probe: proc() -> Harness_Facts

// full: the cached pi_installed and claude_installed answers are dropped too, the login shell's
// about pi included (after an install or update ran: PATH may have changed); else they are kept
// and the binaries are looked for again by stat (harness_facts_now), which finds a harness
// installed since. bump: the Settings tab's rows are built again (not while they are being built).
harness_checklist_refresh :: proc(full := false, bump := true) {
	if full {
		pi_recheck()
		claude_recheck()
	}
	f := harness_facts_probe != nil ? harness_facts_probe() : harness_facts_now()
	items_pi_asking = harness_facts_probe == nil && pi_lookup_state() == .Asking
	for s in items_strings do delete(s)
	clear(&items_strings)
	clear(&harness_items)
	keep :: proc(s: string) -> string {
		if s == "" do return ""
		c := strings.clone(s)
		append(&items_strings, c)
		return c
	}
	for it in harness_checklist(f) {
		x := it
		x.version, x.where_, x.command, x.note = keep(it.version), keep(it.where_), keep(it.command), keep(it.note)
		x.target, x.target_real, x.path_dir, x.pm = keep(it.target), keep(it.target_real), keep(it.path_dir), keep(it.pm)
		append(&harness_items, x)
	}
	if bump do settings_gen += 1 // the Settings tab's Coding agents rows
	window_state_changed()
}

// The checklist is looked at again when it next shows (the shell environment was refreshed).
harness_checklist_forget :: proc() {
	if len(harness_items) == 0 do return
	clear(&harness_items)
	settings_gen += 1
}

// The checklist was made while the login shell was still being asked about pi (pi counted as
// there): made again once it answered. Frame upkeep while the sheet or Settings shows it.
@(private = "file")
items_pi_asking: bool

harness_checklist_tick :: proc() {
	if items_pi_asking && pi_lookup_state() != .Asking do harness_checklist_refresh()
}

// The cached item for a manifest id (nil = none).
harness_item :: proc(id: string) -> ^Harness_Item {
	for &it in harness_items do if HARNESS_MANIFEST[it.row].id == id do return &it
	return nil
}

// Whether the harness counts as installed in the cached checklist.
harness_item_installed :: proc(h: Harness) -> bool {
	for it in harness_items do if HARNESS_MANIFEST[it.row].harness == h && HARNESS_MANIFEST[it.row].kind == .Harness do return it.state != .Missing
	return false
}

HARNESS_STATE_NAMES := [Harness_Item_State]string {
	.Missing       = "missing",
	.Too_Old       = "too_old",
	.Ok            = "ok",
	.Built_In      = "built_in",
	.Not_Loaded    = "not_loaded",
	.Needs_Harness = "needs_harness",
	.Unchecked     = "unchecked",
}
