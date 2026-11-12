package main

// The harness manifest and checklist (harness_manifest.odin) and its install runner
// (harness_install.odin). Fake install layouts under a fake HOME and a fake stand-in command,
// checked by its argv; never a real pi, claude or install command.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
hm_dir :: proc(tag: string) -> string {
	d := fmt.tprintf("%s/deckhand-hm-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	return d
}

@(private = "file")
hm_write :: proc(path, text: string, mode: u16 = 0o644) {
	os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	_ = os.write_entire_file(path, transmute([]u8)text)
	posix.chmod(strings.clone_to_cstring(path, context.temp_allocator), transmute(posix.mode_t)mode)
}

@(private = "file")
hm_link :: proc(target, link: string) {
	os.make_directory_all(link[:strings.last_index_byte(link, '/')])
	os.symlink(target, link)
}

// An environment variable as it was (unset when it was), for a deferred restore.
@(private = "file")
Env_Was :: struct {
	key, value: string,
	found:      bool,
}

@(private = "file")
env_save :: proc(keys: ..string) -> []Env_Was {
	out := make([]Env_Was, len(keys), context.temp_allocator)
	for k, i in keys {
		v, found := os.lookup_env(k, context.temp_allocator)
		out[i] = {k, v, found}
	}
	return out
}

@(private = "file")
env_restore :: proc(saved: []Env_Was) {
	for e in saved {
		if e.found do os.set_env(e.key, e.value)
		else do os.unset_env(e.key)
	}
}

@(private = "file")
row_of :: proc(id: string) -> core.Harness_Row {
	r, _ := core.harness_row(id)
	return r
}

@(private = "file")
item_of :: proc(items: []core.Harness_Item, id: string) -> core.Harness_Item {
	for it in items do if core.HARNESS_MANIFEST[it.row].id == id do return it
	return {}
}

@(test)
harness_manifest_rows_are_whole :: proc(t: ^testing.T) {
	ids := make(map[string]bool, allocator = context.temp_allocator)
	for h in core.Harness {
		n := 0
		for r in core.HARNESS_MANIFEST do if r.harness == h && r.kind == .Harness do n += 1
		testing.expectf(t, n == 1, "%v has one harness row (%d)", h, n)
	}
	for r in core.HARNESS_MANIFEST {
		testing.expectf(t, !(r.id in ids), "%s listed once", r.id)
		ids[r.id] = true
		testing.expectf(t, r.why != "" && r.source != "", "%s has a reason and a source", r.id)
		switch r.kind {
		case .Built_In:    testing.expectf(t, r.install == "" && r.need == .Required, "%s ships in Deckhand: nothing to install", r.id)
		case .Harness:     testing.expectf(t, r.install != "", "%s has an install command", r.id)
		case .Third_Party: testing.expectf(t, r.install != "" && r.detect == .Pi_Package, "%s is installed by its package manager", r.id)
		}
	}
	testing.expect_value(t, row_of("pi").min_version, "1.4.0")
	testing.expect_value(t, row_of("claude").min_version, "2.1.295")
	// the official install commands (pi README "Getting started"; code.claude.com/docs/en/setup)
	// (https only, redirects too)
	testing.expect_value(t, row_of("pi").install, "curl --proto '=https' --proto-redir '=https' -fsSL https://pi.dev/install.sh | sh")
	testing.expect_value(t, row_of("claude").install, "curl --proto '=https' --proto-redir '=https' -fsSL https://claude.ai/install.sh | bash")
	// Claude Code needs nothing third-party (the UI shows an empty Recommended list)
	for r in core.HARNESS_MANIFEST do if r.harness == .Claude do testing.expectf(t, r.kind != .Third_Party, "%s: Claude has no third-party item", r.id)
}

@(test)
harness_layouts :: proc(t: ^testing.T) {
	ad := "/Users/u/.pi/agent"
	cases := [?]struct {
		h:    core.Harness,
		real: string,
		want: core.Install_Layout,
	} {
		{.Pi, "/Users/u/.pi/agent/bin/pi", .Managed},
		{.Pi, "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", .Npm},
		{.Pi, "/Users/u/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", .Bun},
		{.Pi, "/Users/u/Library/pnpm/global/5/.pnpm/x/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", .Pnpm},
		{.Pi, "/Users/u/.config/yarn/global/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", .Yarn},
		{.Pi, "/nix/store/abc-pi-1.5.0/bin/pi", .Nix},
		{.Pi, "/Users/u/.local/share/mise/installs/npm-earendil-works-pi-coding-agent/1.5.0/bin/pi", .Mise},
		{.Pi, "/opt/homebrew/Cellar/pi/1.5.0/bin/pi", .Brew},
		{.Pi, "/usr/local/bin/pi", .Unknown},
		{.Claude, "/Users/u/.local/share/claude/versions/2.1.300", .Managed},
		{.Claude, "/opt/homebrew/Caskroom/claude-code/2.1.300/claude", .Brew},
		{.Claude, "/opt/homebrew/Caskroom/claude-code@latest/2.1.301/claude", .Brew},
		{.Claude, "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", .Npm},
		{.Claude, "/Users/u/.bun/install/global/node_modules/@anthropic-ai/claude-code/cli.js", .Bun},
		{.Claude, "/Users/u/Library/pnpm/claude", .Pnpm},
		{.Claude, "/nix/store/abc-claude-code-2.1.300/bin/claude", .Nix},
		{.Claude, "/Users/u/.local/share/mise/installs/npm-anthropic-ai-claude-code/2.1.300/bin/claude", .Mise},
		{.Claude, "/usr/local/bin/claude", .Unknown},
	}
	for c in cases do testing.expectf(t, core.install_layout(c.h, c.real, ad) == c.want, "%s: %v, want %v", c.real, core.install_layout(c.h, c.real, ad), c.want)
}

// A fake install of Claude Code (or pi) under root in a layout: its binary, the real file it links
// to, and the package manager next to its prefix when pm (an executable stand-in, never run here).
@(private = "file")
Fake_Install :: struct {
	bin, real, pm, prefix: string,
}

@(private = "file")
fake_install :: proc(root: string, layout: core.Install_Layout, pm := true) -> Fake_Install {
	f: Fake_Install
	exe :: "#!/bin/sh\necho 'stand-in (tests): never run' >&2\nexit 1\n"
	switch layout {
	case .Npm:
		f.prefix = fmt.tprintf("%s/nvm/versions/node/v22", root)
		f.real = fmt.tprintf("%s/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", f.prefix)
		if pm do f.pm = fmt.tprintf("%s/bin/npm", f.prefix)
		os.make_directory_all(fmt.tprintf("%s/bin", f.prefix))
	case .Brew:
		f.prefix = fmt.tprintf("%s/homebrew", root)
		f.real = fmt.tprintf("%s/Caskroom/claude-code/2.1.100/claude", f.prefix)
		if pm do f.pm = fmt.tprintf("%s/bin/brew", f.prefix)
	case .Bun:
		f.prefix = fmt.tprintf("%s/.bun", root)
		f.real = fmt.tprintf("%s/install/global/node_modules/@anthropic-ai/claude-code/cli.js", f.prefix)
		if pm do f.pm = fmt.tprintf("%s/bin/bun", f.prefix)
	case .Pnpm:
		f.prefix = fmt.tprintf("%s/Library/pnpm", root)
		f.real = fmt.tprintf("%s/global/5/node_modules/@anthropic-ai/claude-code/cli.js", f.prefix)
		if pm do f.pm = fmt.tprintf("%s/pnpm", f.prefix)
	case .Managed, .Unknown, .Yarn, .Nix, .Mise:
		f.real = fmt.tprintf("%s/.local/share/claude/versions/2.1.100", root)
	}
	hm_write(f.real, exe, 0o755)
	if f.pm != "" do hm_write(f.pm, exe, 0o755)
	f.bin = fmt.tprintf("%s/bin-%v/claude", root, layout)
	hm_link(f.real, f.bin)
	return f
}

// The command each layout runs, aimed at the copy detected: its binary and the package manager next
// to its prefix by absolute path (a login shell's PATH may find another copy), and what Deckhand
// does not run.
@(test)
harness_plans_aim_at_the_detected_copy :: proc(t: ^testing.T) {
	claude := row_of("claude")
	root := hm_dir("plans")
	// native: the detected binary itself
	m := fake_install(root, .Managed)
	p := core.harness_plan(claude, .Update, .Managed, m.bin, m.real)
	testing.expect_value(t, p.command, fmt.tprintf("%s update", m.bin))
	testing.expect(t, p.runnable && p.pm == "")
	// npm under nvm: that prefix's npm, told its prefix; its folder first on PATH
	n := fake_install(root, .Npm)
	p = core.harness_plan(claude, .Update, .Npm, n.bin, n.real)
	testing.expect_value(t, p.command, fmt.tprintf("%s install -g --prefix %s @anthropic-ai/claude-code@latest", n.pm, n.prefix))
	testing.expect(t, p.runnable && p.pm == n.pm && p.path_dir == filepath.dir(n.pm), p.note)
	// Homebrew: the brew of that prefix; bun and pnpm likewise
	br := fake_install(root, .Brew)
	p = core.harness_plan(claude, .Update, .Brew, br.bin, br.real)
	testing.expect_value(t, p.command, fmt.tprintf("%s upgrade --cask claude-code", br.pm))
	testing.expect(t, p.runnable)
	bu := fake_install(root, .Bun)
	p = core.harness_plan(claude, .Update, .Bun, bu.bin, bu.real)
	testing.expect_value(t, p.command, fmt.tprintf("%s add -g @anthropic-ai/claude-code@latest", bu.pm))
	testing.expect(t, p.runnable)
	pn := fake_install(root, .Pnpm)
	p = core.harness_plan(claude, .Update, .Pnpm, pn.bin, pn.real)
	testing.expect_value(t, p.command, fmt.tprintf("%s add -g @anthropic-ai/claude-code@latest", pn.pm))
	testing.expect(t, p.runnable)
	// no package manager next to the prefix (a custom npm prefix): shown only, never a bare npm
	other := hm_dir("plans-nopm")
	np := fake_install(other, .Npm, pm = false)
	p = core.harness_plan(claude, .Update, .Npm, np.bin, np.real)
	testing.expect(t, !p.runnable && strings.contains(p.note, "no npm next to this copy"), p.note)
	// an npm prefix that needs sudo: shown only
	ro := hm_dir("plans-ro")
	nr := fake_install(ro, .Npm)
	posix.chmod(strings.clone_to_cstring(fmt.tprintf("%s/lib/node_modules", nr.prefix), context.temp_allocator), transmute(posix.mode_t)u16(0o555))
	defer posix.chmod(strings.clone_to_cstring(fmt.tprintf("%s/lib/node_modules", nr.prefix), context.temp_allocator), transmute(posix.mode_t)u16(0o755))
	p = core.harness_plan(claude, .Update, .Npm, nr.bin, nr.real)
	testing.expect(t, !p.runnable && strings.contains(p.note, "sudo"), p.note)
	// pi: the detected pi updates itself; nix, mise, yarn, unknown are shown only
	pi := row_of("pi")
	p = core.harness_plan(pi, .Update, .Managed, "/Users/u/.pi/agent/bin/pi", "/Users/u/.pi/agent/bin/pi")
	testing.expect(t, p.runnable && p.command == "/Users/u/.pi/agent/bin/pi update --self")
	p = core.harness_plan(pi, .Update, .Nix, "/nix/x/pi", "/nix/store/abc/bin/pi")
	testing.expect(t, !p.runnable && p.command == "nix profile upgrade pi")
	for l in ([]core.Install_Layout{.Mise, .Yarn, .Unknown}) do testing.expectf(t, !core.harness_plan(claude, .Update, l, m.bin, m.real).runnable, "%v shown only", l)
	testing.expect_value(t, core.harness_plan(pi, .Update, .Brew, "/x/pi", "/opt/homebrew/Cellar/pi/1/bin/pi").command, "")
	// found through the login shell only (no path): shown only
	testing.expect(t, !core.harness_plan(claude, .Update, .Managed, "", "").runnable)
	// a path with spaces is quoted
	testing.expect_value(t, core.harness_plan(claude, .Update, .Managed, "/Users/a b/claude", "/x/claude/versions/1").command, "'/Users/a b/claude' update")
	// an install: the official installer as it is
	p = core.harness_plan(claude, .Install, .Unknown, "", "")
	testing.expect(t, p.runnable && p.command == claude.install)
	// a third-party package: the detected pi installs it
	sa := row_of("pi-subagents")
	testing.expect_value(t, core.harness_plan(sa, .Install, .Npm, "/p/pi", "/p/real", "/p/pi").command, "/p/pi install npm:pi-subagents@0.84.0")
	testing.expect(t, !core.harness_plan(sa, .Install, .Npm, "", "", "").runnable, "no pi path: shown only")
	// the version bar's command keeps bare names
	testing.expect_value(t, core.claude_update_command(n.real), "npm install -g @anthropic-ai/claude-code@latest")
	testing.expect_value(t, core.claude_update_command("/opt/homebrew/Caskroom/claude-code@latest/2.1.0/claude"), "brew upgrade --cask claude-code@latest")
}

@(private = "file")
facts_both :: proc(root: string) -> core.Harness_Facts {
	f: core.Harness_Facts
	f.agent_dir = fmt.tprintf("%s/.pi/agent", root)
	f.installed = {.Pi = true, .Claude = true, .Codex = true}
	// pi from npm under a prefix with its npm; Claude Code from its native installer; Codex from npm
	prefix := fmt.tprintf("%s/opt", root)
	pi_real := fmt.tprintf("%s/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", prefix)
	hm_write(pi_real, "#!/bin/sh\nexit 1\n", 0o755)
	hm_write(fmt.tprintf("%s/bin/npm", prefix), "#!/bin/sh\nexit 1\n", 0o755)
	hm_link(pi_real, fmt.tprintf("%s/bin/pi", prefix))
	c := fake_install(root, .Managed)
	codex_real := fmt.tprintf("%s/lib/node_modules/@openai/codex/bin/codex.js", prefix)
	hm_write(codex_real, "#!/bin/sh\nexit 1\n", 0o755)
	hm_link(codex_real, fmt.tprintf("%s/bin/codex", prefix))
	f.bin = {.Pi = fmt.tprintf("%s/bin/pi", prefix), .Claude = c.bin, .Codex = fmt.tprintf("%s/bin/codex", prefix)}
	f.real = {.Pi = pi_real, .Claude = c.real, .Codex = codex_real}
	f.version = {.Pi = "1.5.0", .Claude = "2.1.300", .Codex = "0.167.2"}
	f.integration = {.Pi = true, .Claude = true, .Codex = true}
	f.packages = make(map[string]core.Pi_Package_Found, allocator = context.temp_allocator)
	f.packages["pi-subagents"] = {listed = true, spec = "0.84.0", installed = "0.84.0"}
	f.packages["@juicesharp/rpiv-todo"] = {listed = true, spec = "2.15.0"}
	f.packages["pi-ask-user"] = {listed = true, spec = "0.17.0", installed = "0.17.0"}
	f.packages["pi-web-access"] = {listed = true, installed = "0.46.0"} // unpinned: the installed copy's version
	f.packages["@juicesharp/rpiv-btw"] = {listed = true, spec = "2.15.0"}
	return f
}

@(test)
harness_checklist_states :: proc(t: ^testing.T) {
	root := hm_dir("states")
	// everything there and new enough: no action anywhere
	items := core.harness_checklist(facts_both(root))
	testing.expect_value(t, len(items), len(core.HARNESS_MANIFEST))
	for it in items do testing.expectf(t, it.action == .None, "%s: no action (%v)", core.HARNESS_MANIFEST[it.row].id, it.action)
	testing.expect_value(t, item_of(items, "pi").layout, core.Install_Layout.Npm)
	testing.expect_value(t, item_of(items, "claude").layout, core.Install_Layout.Managed)
	testing.expect_value(t, item_of(items, "pi-integration").state, core.Harness_Item_State.Built_In)
	testing.expect_value(t, item_of(items, "rpiv-todo").version, "2.15.0")
	testing.expect_value(t, item_of(items, "pi-web-access").version, "0.46.0")

	// missing: Install with the official command; pi's packages wait for pi
	f := facts_both(root)
	f.installed = {}
	f.bin, f.real, f.version = {}, {}, {}
	items = core.harness_checklist(f)
	for id in ([]string{"pi", "claude", "codex"}) {
		it := item_of(items, id)
		testing.expectf(t, it.state == .Missing && it.action == .Install && it.runnable && it.command == row_of(id).install && it.target == "", "%s missing: Install (%v)", id, it)
	}
	testing.expect_value(t, item_of(items, "pi-subagents").state, core.Harness_Item_State.Needs_Harness)

	// too old: Update aimed at the detected copy (its path, the npm next to it)
	f = facts_both(root)
	f.version = {.Pi = "1.3.2", .Claude = "2.1.100", .Codex = "0.141.0"}
	items = core.harness_checklist(f)
	pi, cl := item_of(items, "pi"), item_of(items, "claude")
	// Codex older than 0.163.0 (OSC 7501): Update with the npm next to it
	cx := item_of(items, "codex")
	testing.expectf(t, cx.state == .Too_Old && cx.runnable && cx.command == fmt.tprintf("%s/opt/bin/npm install -g --prefix %s/opt @openai/codex@latest", root, root) && cx.target == f.bin[.Codex], "codex too old: %v", cx)
	testing.expect(t, pi.state == .Too_Old && pi.runnable && pi.command == fmt.tprintf("%s update --self", f.bin[.Pi]), pi.command)
	testing.expect(t, pi.target == f.bin[.Pi] && pi.target_real == f.real[.Pi] && pi.path_dir == fmt.tprintf("%s/opt/bin", root), pi.path_dir)
	testing.expect(t, cl.state == .Too_Old && cl.runnable && cl.command == fmt.tprintf("%s update", f.bin[.Claude]) && cl.target == f.bin[.Claude])
	testing.expect_value(t, item_of(items, "pi-integration").state, core.Harness_Item_State.Not_Loaded)

	// too old on nix and mise: shown only
	f.real = {.Pi = "/nix/store/abc-pi-1.3.2/bin/pi", .Claude = "/Users/u/.local/share/mise/installs/npm-anthropic-ai-claude-code/2.1.100/bin/claude", .Codex = f.real[.Codex]}
	items = core.harness_checklist(f)
	pi, cl = item_of(items, "pi"), item_of(items, "claude")
	testing.expect(t, pi.action == .Update && !pi.runnable && pi.command == "nix profile upgrade pi" && pi.note != "")
	testing.expect(t, cl.action == .Update && !cl.runnable && cl.command == "" && strings.contains(cl.note, "mise"))

	// a third-party package: not listed, Install by the detected pi; older than its minimum, Update
	f = facts_both(root)
	f.packages["pi-subagents"] = {listed = true, spec = "", installed = "0.80.1"}
	f.packages["@juicesharp/rpiv-todo"] = {}
	items = core.harness_checklist(f)
	sa, todo := item_of(items, "pi-subagents"), item_of(items, "rpiv-todo")
	testing.expect(t, sa.state == .Too_Old && sa.runnable && sa.command == fmt.tprintf("%s install npm:pi-subagents@0.84.0", f.bin[.Pi]) && sa.target == f.bin[.Pi], sa.command)
	testing.expect(t, todo.state == .Missing && todo.runnable && todo.command == fmt.tprintf("%s install npm:@juicesharp/rpiv-todo@2.15.0", f.bin[.Pi]))
	// the other recommended packages: each a pinned install; pi-web-access below its advisory fix, Update
	f.packages["pi-ask-user"], f.packages["@juicesharp/rpiv-btw"] = {}, {}
	f.packages["pi-web-access"] = {listed = true, installed = "0.24.0"}
	items = core.harness_checklist(f)
	for c in ([][2]string{{"pi-ask-user", "npm:pi-ask-user@0.17.0"}, {"rpiv-btw", "npm:@juicesharp/rpiv-btw@2.15.0"}}) {
		it := item_of(items, c[0])
		testing.expectf(t, it.state == .Missing && it.runnable && it.command == fmt.tprintf("%s install %s", f.bin[.Pi], c[1]), "%s: %v", c[0], it)
	}
	wa := item_of(items, "pi-web-access")
	testing.expect(t, wa.state == .Too_Old && wa.action == .Update && wa.command == fmt.tprintf("%s install npm:pi-web-access@0.47.0", f.bin[.Pi]), wa.command)
	// found from a git or local source: found, its version unchecked, nothing offered (no second copy)
	f.packages["@juicesharp/rpiv-todo"] = {listed = true, other = true}
	todo = item_of(core.harness_checklist(f), "rpiv-todo")
	testing.expect(t, todo.state == .Unchecked && todo.action == .None && strings.contains(todo.note, "git or local"), todo.note)

	// not in this build: said so
	f = facts_both(root)
	f.integration[.Claude] = false
	testing.expect_value(t, item_of(core.harness_checklist(f), "claude-plugin").state, core.Harness_Item_State.Not_Loaded)
	// a version nobody can read: fine, never "too old"
	f = facts_both(root)
	f.version = {}
	items = core.harness_checklist(f)
	testing.expect_value(t, item_of(items, "pi").state, core.Harness_Item_State.Ok)
	testing.expect_value(t, item_of(items, "claude").state, core.Harness_Item_State.Ok)
}

@(test)
harness_pi_packages_read :: proc(t: ^testing.T) {
	ad := hm_dir("pkgs")
	hm_write(fmt.tprintf("%s/settings.json", ad), `{
  "packages": [
    "npm:pi-ask-user@0.17.0",
    {"source": "npm:pi-subagents@0.84.0", "prompts": ["!prompts/x.md"]},
    "npm:@juicesharp/rpiv-todo"
  ]
}`)
	hm_write(fmt.tprintf("%s/npm/node_modules/@juicesharp/rpiv-todo/package.json", ad), `{"name":"@juicesharp/rpiv-todo","version":"2.16.1"}`)
	sa := core.pi_package_find(ad, "pi-subagents")
	testing.expect(t, sa.listed && !sa.other && sa.spec == "0.84.0" && sa.installed == "")
	todo := core.pi_package_find(ad, "@juicesharp/rpiv-todo")
	testing.expect(t, todo.listed && todo.spec == "" && todo.installed == "2.16.1")
	testing.expect(t, !core.pi_package_find(ad, "pi-fff").listed)
	testing.expect(t, !core.pi_package_find(fmt.tprintf("%s/none", ad), "pi-subagents").listed, "no settings.json: nothing listed")
	data, _ := os.read_entire_file(fmt.tprintf("%s/settings.json", ad), context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"npm:pi-ask-user@0.17.0"`), "read only")

	// git and local sources of the same name are found (another copy would be a second one)
	ad2 := hm_dir("pkgs-git")
	hm_write(fmt.tprintf("%s/settings.json", ad2), `{"packages": ["git:github.com/someone/pi-subagents@v1", {"source": "../../code/rpiv-todo/"}]}`)
	sa = core.pi_package_find(ad2, "pi-subagents")
	testing.expect(t, sa.listed && sa.other, "a git source")
	todo = core.pi_package_find(ad2, "@juicesharp/rpiv-todo")
	testing.expect(t, todo.listed && todo.other, "a local folder of the package's name")
	testing.expect(t, !core.pi_package_find(ad2, "pi-ask-user").listed)
	// a project's .pi/settings.json is read too, and only noted (never "listed": pi's own settings decide)
	proj := hm_dir("pkgs-proj")
	hm_write(fmt.tprintf("%s/.pi/settings.json", proj), `{"packages": ["npm:pi-ask-user@0.17.0"]}`)
	testing.expect(t, !core.pi_package_find(ad2, "pi-ask-user").project)
	ask := core.pi_package_find(ad2, "pi-ask-user", proj)
	testing.expect(t, !ask.listed && ask.project && ask.project_spec == "0.17.0", "the project's settings")
}

// The facts from a fake HOME's install layouts (test mode: never PATH): pi's managed install linked
// into an npm-like package, Claude Code's native installer.
@(test)
harness_facts_from_layouts :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // the checklist and the runner are global state
	home := hm_dir("home")
	saved := env_save("HOME", "DECKHAND_SCRIPT", "DECKHAND_CMD", "DECKHAND_CLAUDE_CMD", "PI_CODING_AGENT_DIR")
	defer {
		env_restore(saved)
		core.pi_recheck()
		core.claude_recheck()
	}
	os.set_env("HOME", home)
	os.set_env("DECKHAND_SCRIPT", "unit-test") // test mode: the install folders only, never PATH
	os.set_env("DECKHAND_CMD", "")
	os.set_env("DECKHAND_CLAUDE_CMD", "")
	os.unset_env("PI_CODING_AGENT_DIR")
	pkg := fmt.tprintf("%s/.pi/agent/lib/node_modules/@earendil-works/pi-coding-agent", home)
	hm_write(fmt.tprintf("%s/package.json", pkg), `{"name":"@earendil-works/pi-coding-agent","version":"1.3.0"}`)
	hm_write(fmt.tprintf("%s/dist/cli.js", pkg), "#!/usr/bin/env node\n", 0o755)
	hm_link(fmt.tprintf("%s/dist/cli.js", pkg), fmt.tprintf("%s/.pi/agent/bin/pi", home))
	hm_write(fmt.tprintf("%s/.local/share/claude/versions/2.1.300", home), "#!/bin/sh\nexit 0\n", 0o755)
	hm_link(fmt.tprintf("%s/.local/share/claude/versions/2.1.300", home), fmt.tprintf("%s/.local/bin/claude", home))
	core.pi_recheck()
	core.claude_recheck()
	f := core.harness_facts_now()
	testing.expect(t, f.installed[.Pi] && f.installed[.Claude])
	testing.expect_value(t, f.version[.Pi], "1.3.0")
	testing.expect_value(t, f.version[.Claude], "2.1.300")
	items := core.harness_checklist(f)
	pi := item_of(items, "pi")
	testing.expect(t, pi.state == .Too_Old && pi.layout == .Managed && pi.runnable && pi.command == fmt.tprintf("%s/.pi/agent/bin/pi update --self", home), pi.command)
	testing.expect_value(t, item_of(items, "claude").state, core.Harness_Item_State.Ok)
	testing.expect_value(t, item_of(items, "claude").layout, core.Install_Layout.Managed)

	// nothing there: both missing (pi's login-shell lookup is never asked in test mode)
	empty := hm_dir("empty")
	os.set_env("HOME", empty)
	core.pi_recheck()
	core.claude_recheck()
	f = core.harness_facts_now()
	testing.expect(t, !f.installed[.Pi] && !f.installed[.Claude])
}

@(test)
harness_run_argv_and_script :: proc(t: ^testing.T) {
	claude := row_of("claude")
	plan := core.Harness_Run_Plan{command = claude.install, no_sudo = "/tmp/ns"}
	// test mode with a stand-in: the same prelude (no sudo), then the item's id and the exact command
	argv, refused := core.harness_run_argv(claude, .Install, plan, true, "/fake/install")
	testing.expect(t, !refused)
	testing.expect_value(t, len(argv), 6)
	if len(argv) == 6 {
		testing.expect_value(t, argv[0], "/bin/sh")
		testing.expect(t, strings.has_prefix(argv[2], "PATH='/tmp/ns':\"$PATH\"; ") && strings.contains(argv[2], "SUDO_ASKPASS=/usr/bin/false") && strings.has_suffix(argv[2], `/fake/install "$@"`), argv[2])
		testing.expect_value(t, argv[4], "claude")
		testing.expect_value(t, argv[5], claude.install)
	}
	argv, refused = core.harness_run_argv(claude, .Install, plan, true, "")
	testing.expect(t, refused)
	for a in argv do testing.expect(t, !strings.contains(a, "claude.ai"), "the refusal never names the real install")
	// the real script (built, never run with a real command here)
	s := core.harness_run_script(claude, .Install, plan)
	testing.expect(t, strings.contains(s, "command -v claude") && strings.contains(s, "$HOME/.local/bin/claude") && strings.contains(s, "Deckhand does not install a second copy"))
	testing.expect(t, strings.contains(s, claude.install) && strings.contains(s, "SUDO_ASKPASS=/usr/bin/false"))
	u := core.harness_run_script(claude, .Update, {command = "/x/claude update", target = "/x/claude", target_real = "/y/2.1.0"})
	testing.expect(t, !strings.contains(u, "second copy") && strings.contains(u, "_t='/x/claude'; _d='/y/2.1.0'"))
	testing.expect_value(t, core.sh_quote("it's"), `'it'\''s'`)
}

// The script, run with stand-ins only: it updates the copy Deckhand detected, and refuses when that
// copy is gone or links elsewhere now (a reinstall since), naming both.
@(test)
harness_run_script_checks_the_target :: proc(t: ^testing.T) {
	root := hm_dir("target")
	marker := fmt.tprintf("%s/ran.txt", root)
	real := fmt.tprintf("%s/share/claude/versions/2.1.100", root)
	hm_write(real, fmt.tprintf("#!/bin/sh\necho \"$@\" >> '%s'\n", marker), 0o755)
	bin := fmt.tprintf("%s/bin/claude", root)
	hm_link(real, bin)
	real_now := core.fs_real(real)
	claude := row_of("claude")
	run :: proc(r: core.Harness_Row, plan: core.Harness_Run_Plan) -> (string, int) {
		argv := [?]string{"/bin/sh", "-c", core.harness_run_script(r, .Update, plan), "sh"}
		out, code, _ := core.run_bounded_exit("", argv[:], 10 * time.Second)
		return out, code
	}
	plan := core.Harness_Run_Plan{command = fmt.tprintf("%s update", core.sh_word(bin)), target = bin, target_real = real_now}
	out, code := run(claude, plan)
	testing.expectf(t, code == 0, "the detected copy updates: %d %s", code, out)
	ran, _ := os.read_entire_file(marker, context.temp_allocator)
	testing.expect_value(t, string(ran), "update\n")
	// relinked to another copy since: refused, both named, nothing run
	other := fmt.tprintf("%s/other/claude", root)
	hm_write(other, fmt.tprintf("#!/bin/sh\necho OTHER >> '%s'\n", marker), 0o755)
	os.remove(bin)
	hm_link(other, bin)
	out, code = run(claude, plan)
	testing.expectf(t, code == 1 && strings.contains(out, real_now) && strings.contains(out, core.fs_real(other)), "refused, naming both: %d %s", code, out)
	ran, _ = os.read_entire_file(marker, context.temp_allocator)
	testing.expect_value(t, string(ran), "update\n")
	// gone: refused
	os.remove(bin)
	out, code = run(claude, plan)
	testing.expectf(t, code == 1 && strings.contains(out, "not there now"), "gone: %d %s", code, out)
	// its package manager gone: refused
	hm_link(real, bin)
	plan.pm = fmt.tprintf("%s/nowhere/npm", root)
	out, code = run(claude, plan)
	testing.expectf(t, code == 1 && strings.contains(out, "the package manager next to this copy"), "no pm: %d %s", code, out)
	// an install's guard: PI_CODING_AGENT_DIR with a "~/" is expanded as pi reads it
	home := hm_dir("guard-home")
	hm_write(fmt.tprintf("%s/agent/bin/pi", home), "#!/bin/sh\nexit 1\n", 0o755)
	saved := env_save("HOME", "PI_CODING_AGENT_DIR", "PATH")
	defer env_restore(saved)
	os.set_env("HOME", home)
	os.set_env("PI_CODING_AGENT_DIR", "~/agent")
	os.set_env("PATH", "/usr/bin:/bin")
	pi := row_of("pi")
	argv := [?]string{"/bin/sh", "-c", core.harness_run_script(pi, .Install, {command = "echo INSTALLER-RAN; exit 3"}), "sh"}
	out, code, _ = core.run_bounded_exit("", argv[:], 10 * time.Second)
	testing.expectf(t, code == 0 && strings.contains(out, "already installed") && !strings.contains(out, "\nINSTALLER-RAN"), "the guard found ~/agent/bin/pi: %d %s", code, out)
}

// sudo refuses inside a run (the stand-in tries it), with SUDO_ASKPASS=/usr/bin/false.
@(test)
harness_run_never_sudo :: proc(t: ^testing.T) {
	root := hm_dir("sudo")
	fake := fmt.tprintf("%s/fake.sh", root)
	hm_write(fake, "#!/bin/sh\nsudo true 2>&1; echo \"sudo exit $?\"; echo \"askpass $SUDO_ASKPASS\"\n", 0o755)
	cmd := "npm install -g x"
	ns := core.harness_no_sudo_dir(cmd)
	defer os.remove_all(ns)
	testing.expect(t, ns != "")
	argv, _ := core.harness_run_argv(row_of("claude"), .Update, {command = cmd, no_sudo = ns}, true, fake)
	out, code, _ := core.run_bounded_exit("", argv[:], 10 * time.Second)
	testing.expectf(t, code == 0 && strings.contains(out, "Deckhand doesn't run sudo; run this yourself:") && strings.contains(out, "  npm install -g x") && strings.contains(out, "sudo exit 1") && strings.contains(out, "askpass /usr/bin/false"), "%d %s", code, out)
}

// Keys reach the run's terminal only while it runs and shows, never ⌘ keys, and not Enter in the
// first second after the click (the habitual Enter must not answer a y/N).
@(test)
harness_run_keys :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := core.harness_run
	defer core.harness_run = saved
	now := time.tick_now()
	core.harness_run = {status = .Running, started = now}
	enter := sapp.Event{type = .KEY_DOWN, key_code = .ENTER}
	cr := sapp.Event{type = .CHAR, char_code = '\r'}
	a := sapp.Event{type = .CHAR, char_code = 'y'}
	testing.expect(t, !harness_run_takes_key(&enter, true, now), "Enter at once: not the terminal's")
	testing.expect(t, !harness_run_takes_key(&cr, true, time.tick_add(now, 500 * time.Millisecond)))
	testing.expect(t, harness_run_takes_key(&a, true, now), "other keys are")
	testing.expect(t, harness_run_takes_key(&enter, true, time.tick_add(now, 1100 * time.Millisecond)), "Enter after a second is")
	testing.expect(t, !harness_run_takes_key(&a, false, now), "never while the terminal does not show")
	q := sapp.Event{type = .KEY_DOWN, key_code = .Q, modifiers = sapp.MODIFIER_SUPER}
	testing.expect(t, !harness_run_takes_key(&q, true, now), "⌘Q quits")
	core.harness_run.status = .Done
	testing.expect(t, !harness_run_takes_key(&a, true, now), "a finished run takes nothing")
}

// An agent cannot move the keyboard off the setup sheet while an install runs there; the user can.
@(test)
harness_run_holds_the_sheet :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := core.harness_run
	defer core.harness_run = saved
	old := state.focus_widget
	defer state.focus_widget = old
	state.focus_widget = "setup"
	core.harness_run = {status = .Running}
	for kind in ([]core.Caller_Kind{.Control, .Script}) {
		r := core.run_command(core.Set_Focus{widget = ""}, {kind = kind})
		testing.expectf(t, !r.ok && strings.contains(r.error, "install is running"), "%v: %v", kind, r.error)
		testing.expect_value(t, state.focus_widget, "setup")
	}
	core.harness_run.status = .Done
	testing.expect(t, core.run_command(core.Set_Focus{widget = ""}, {kind = .Control}).ok, "after the run, as before")
	state.focus_widget = "setup"
	core.harness_run.status = .Running
	testing.expect(t, !core.run_command(core.Set_Focus{widget = ""}, {kind = .UI}).ok, "nor the user, while it runs (harness_run_keeps_the_sheet)")
}

// A run end to end with a fake stand-in (it records its argv and "installs" Claude Code into the
// fake HOME): Running, then Done, and the checklist found it.
@(test)
harness_run_with_fake_command :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // the checklist and the runner are global state
	home := hm_dir("run")
	saved := env_save("HOME", "DECKHAND_SCRIPT", "DECKHAND_CLAUDE_CMD", "DECKHAND_INSTALL_CMD")
	defer {
		core.harness_run_dismiss()
		env_restore(saved)
		core.claude_recheck()
		core.pi_recheck()
	}
	os.set_env("HOME", home)
	os.set_env("DECKHAND_SCRIPT", "unit-test")
	os.set_env("DECKHAND_CLAUDE_CMD", "")
	fake := fmt.tprintf("%s/fake-install.sh", home)
	hm_write(fake, `#!/bin/sh
printf '%s\n' "$@" > "$HOME/install-argv.txt"
mkdir -p "$HOME/.local/share/claude/versions" "$HOME/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/share/claude/versions/2.1.300"
chmod 755 "$HOME/.local/share/claude/versions/2.1.300"
ln -s "$HOME/.local/share/claude/versions/2.1.300" "$HOME/.local/bin/claude"
`, 0o755)
	os.set_env("DECKHAND_INSTALL_CMD", fake)
	core.claude_recheck()
	core.harness_checklist_refresh()
	it := core.harness_item("claude")
	testing.expect(t, it != nil && it.state == .Missing && it.action == .Install)
	testing.expect_value(t, core.harness_run_start("pi-integration"), "Deckhand's pi integration needs nothing")
	testing.expect_value(t, core.harness_run_start("claude"), "")
	testing.expect_value(t, core.harness_run.status, core.Harness_Run_Status.Running)
	testing.expect(t, core.harness_run_start("claude") != "", "one run at a time")
	deadline := time.tick_now()
	for core.harness_run.status == .Running && time.tick_since(deadline) < 10 * time.Second {
		core.pump_all()
		time.sleep(20 * time.Millisecond)
	}
	testing.expect_value(t, core.harness_run.status, core.Harness_Run_Status.Done)
	argv, _ := os.read_entire_file(fmt.tprintf("%s/install-argv.txt", home), context.temp_allocator)
	testing.expect_value(t, string(argv), fmt.tprintf("claude\n%s\n", row_of("claude").install))
	it = core.harness_item("claude")
	testing.expect(t, it != nil && it.state == .Ok && it.version == "2.1.300" && it.action == .None, "found after the run, never offered again")
	testing.expect_value(t, core.harness_run_start("claude"), "Claude Code needs nothing")
}

// ---- round 2 ----

// A project's .pi/settings.json never makes a package Ok: pi's own settings decide the state; a
// project's listing adds a note, and its npm version is checked against the minimum too. A git or
// local source cannot be version-checked: found, said so, never plain Ok.
@(test)
harness_pi_packages_project_and_sources :: proc(t: ^testing.T) {
	root := hm_dir("pkg-r2")
	ad := fmt.tprintf("%s/agent", root)
	proj := fmt.tprintf("%s/proj", root)
	hm_write(fmt.tprintf("%s/.pi/settings.json", proj), `{"packages": ["npm:pi-subagents@0.50.0", "git:github.com/x/rpiv-todo"]}`)
	// nothing in pi's own settings: the project's listings are noted, the state is pi's
	sa := core.pi_package_find(ad, "pi-subagents", proj)
	testing.expect(t, !sa.listed && sa.project && sa.project_spec == "0.50.0", "a project's npm listing")
	todo := core.pi_package_find(ad, "@juicesharp/rpiv-todo", proj)
	testing.expect(t, !todo.listed && todo.project && todo.project_spec == "", "a project's git listing")

	f := facts_both(root)
	f.packages["pi-subagents"] = sa
	f.packages["@juicesharp/rpiv-todo"] = todo
	items := core.harness_checklist(f)
	it := item_of(items, "pi-subagents")
	testing.expectf(t, it.state == .Missing && it.action == .Install && it.runnable && strings.contains(it.note, "listed in this project's settings"), "project only: still Install (%v %q)", it.state, it.note)
	it = item_of(items, "rpiv-todo")
	testing.expectf(t, it.state == .Missing && it.action == .Install, "a project's git source: still Install (%v)", it.state)

	// pi's own 0.84.0, the project's 0.50.0: below the pin, said where
	f.packages["pi-subagents"] = {listed = true, spec = "0.84.0", installed = "0.84.0", project = true, project_spec = "0.50.0"}
	it = item_of(core.harness_checklist(f), "pi-subagents")
	testing.expectf(t, it.state == .Too_Old && strings.contains(it.note, "0.50.0") && strings.contains(it.note, "project"), "the project's old pin (%v %q)", it.state, it.note)

	// pi's own settings from git or a local folder: found, version not checked
	f.packages["pi-subagents"] = {listed = true, other = true}
	it = item_of(core.harness_checklist(f), "pi-subagents")
	testing.expectf(t, it.state == .Unchecked && it.action == .None && strings.contains(it.note, "can't check its version"), "git/local: unchecked (%v %q)", it.state, it.note)
	testing.expect_value(t, core.HARNESS_STATE_NAMES[.Unchecked], "unchecked")
}

// Placeholders fill in one pass: a path holding "{pm}" stays one quoted word; a prefix Deckhand
// could not place reads PREFIX (never "<prefix>", a redirect when pasted).
@(test)
harness_plan_placeholders :: proc(t: ^testing.T) {
	claude := row_of("claude")
	p := core.harness_plan(claude, .Update, .Managed, "/x/a{pm}b/claude", "/x/claude/versions/2.1.0")
	testing.expect_value(t, p.command, "'/x/a{pm}b/claude' update")
	p = core.harness_plan(claude, .Update, .Npm, "/x/claude", "/somewhere/odd/claude.js")
	testing.expectf(t, strings.contains(p.command, "PREFIX") && !strings.contains(p.command, "<"), "%q", p.command)
}

// The target check: /bin/realpath (a realpath on the run's PATH cannot stand in), checked before the
// run's PATH changes; a realpath that prints nothing, or none at all, refuses.
@(test)
harness_run_realpath_fails_closed :: proc(t: ^testing.T) {
	root := hm_dir("rp")
	marker := fmt.tprintf("%s/ran.txt", root)
	real := fmt.tprintf("%s/v/2.1.100", root)
	hm_write(real, "#!/bin/sh\nexit 0\n", 0o755)
	bin := fmt.tprintf("%s/bin/claude", root)
	hm_link(real, bin)
	real_now := core.fs_real(real)
	// relinked since; a lying realpath first on the run's PATH says it is still the detected one
	other := fmt.tprintf("%s/other/claude", root)
	hm_write(other, "#!/bin/sh\nexit 0\n", 0o755)
	os.remove(bin)
	hm_link(other, bin)
	liar := fmt.tprintf("%s/liar", root)
	hm_write(fmt.tprintf("%s/realpath", liar), fmt.tprintf("#!/bin/sh\necho '%s'\n", real_now), 0o755)
	claude := row_of("claude")
	cmd := fmt.tprintf("echo RAN > '%s'", marker)
	run :: proc(r: core.Harness_Row, plan: core.Harness_Run_Plan) -> (string, int) {
		argv := [?]string{"/bin/sh", "-c", core.harness_run_script(r, .Update, plan), "sh"}
		out, code, _ := core.run_bounded_exit("", argv[:], 10 * time.Second)
		return out, code
	}
	out, code := run(claude, {command = cmd, target = bin, target_real = real_now, path_dir = liar})
	testing.expectf(t, code == 1 && core.path_kind(marker) == .Missing, "a realpath on the run's PATH does not decide: %d %s", code, out)
	// a realpath that prints nothing: refused
	saved := core.harness_realpath
	defer core.harness_realpath = saved
	os.remove(bin)
	hm_link(real, bin)
	empty := fmt.tprintf("%s/empty-realpath", root)
	hm_write(empty, "#!/bin/sh\nexit 0\n", 0o755)
	core.harness_realpath = empty
	out, code = run(claude, {command = cmd, target = bin, target_real = real_now})
	testing.expectf(t, code == 1 && core.path_kind(marker) == .Missing && strings.contains(out, "could not resolve"), "silent realpath: %d %s", code, out)
	// none at all (no /bin one, none on PATH): refused
	core.harness_realpath = fmt.tprintf("%s/no-such-realpath", root)
	env := env_save("PATH")
	defer env_restore(env)
	os.set_env("PATH", fmt.tprintf("%s/nothing-here", root))
	argv := [?]string{"/bin/sh", "-c", core.harness_run_script(claude, .Update, {command = cmd, target = bin, target_real = real_now}), "sh"}
	out, code, _ = core.run_bounded_exit("", argv[:], 10 * time.Second)
	testing.expectf(t, code == 1 && core.path_kind(marker) == .Missing, "no realpath: %d %s", code, out)
	// and the detected copy, unchanged, with /bin/realpath: runs
	core.harness_realpath = saved
	out, code = run(claude, {command = cmd, target = bin, target_real = real_now})
	testing.expectf(t, code == 0 && core.path_kind(marker) == .File, "unchanged: %d %s", code, out)
}

// The no-sudo folder: its sudo executable; when it cannot be made the run does not start; leftovers
// go at quit (this process's) and at start (those of processes gone).
@(test)
harness_no_sudo_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	root := hm_dir("nosudo")
	env := env_save("TMPDIR", "DECKHAND_SCRIPT", "DECKHAND_INSTALL_CMD")
	defer env_restore(env)
	// test mode, no stand-in: even if harness_run_start went on, it would refuse (never a real run)
	os.set_env("DECKHAND_SCRIPT", "unit-test")
	os.unset_env("DECKHAND_INSTALL_CMD")
	os.set_env("TMPDIR", root)
	d := core.harness_no_sudo_dir("x")
	testing.expect(t, d != "")
	st: posix.stat_t
	testing.expect(t, posix.stat(strings.clone_to_cstring(fmt.tprintf("%s/sudo", d), context.temp_allocator), &st) == .OK && (u32(transmute(u16)st.st_mode) & 0o111) == 0o111, "the shim is executable")
	// leftovers: a dead process's goes at start; ours at quit
	dead := fmt.tprintf("%s/deckhand-no-sudo-999999-1", root)
	os.make_directory(dead)
	// others' entries are left alone (and only names like ours are looked at: no_sudo_names)
	other_dir := fmt.tprintf("%s/not-deckhand-no-sudo-999999-1", root)
	other_file := fmt.tprintf("%s/deckhand-no-sudo-999999-2", root) // a file, not a folder
	os.make_directory(other_dir)
	_ = os.write_entire_file(other_file, transmute([]u8)string("x"))
	names := core.no_sudo_names(root)
	testing.expectf(t, len(names) == 3, "only the names with our prefix: %v", names)
	core.harness_no_sudo_sweep(at_quit = false)
	testing.expect(t, core.path_kind(dead) == .Missing, "a gone process's leftover removed at start")
	testing.expect(t, core.path_kind(other_dir) == .Dir && core.path_kind(other_file) == .File, "others' entries untouched")
	testing.expect(t, core.path_kind(d) == .Dir, "ours stays while we run")
	core.harness_no_sudo_sweep(at_quit = true)
	testing.expect(t, core.path_kind(d) == .Missing, "ours removed at quit")
	// cannot be made: the run does not start
	os.set_env("TMPDIR", fmt.tprintf("%s/no/such/dir", root))
	testing.expect_value(t, core.harness_no_sudo_dir("x"), "")
	saved_items := core.harness_items
	core.harness_items = {}
	defer {
		delete(core.harness_items)
		core.harness_items = saved_items
	}
	append(&core.harness_items, core.Harness_Item{row = core.harness_first_row(.Claude), state = .Missing, action = .Install, command = row_of("claude").install, runnable = true})
	why := core.harness_run_start("claude")
	testing.expectf(t, strings.contains(why, "sudo"), "refused: %q", why)
	testing.expect(t, core.harness_run.status != .Running)
	if core.harness_run.status == .Running do core.harness_run_dismiss()
}

// While an install runs on the setup sheet nothing moves the keyboard off it, the user's menus
// included (⌘, a job sheet, the agent's drawer, closing the sheet): its terminal (⌃C) stays reachable.
@(test)
harness_run_keeps_the_sheet :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := core.harness_run
	defer core.harness_run = saved
	old := state.focus_widget
	defer state.focus_widget = old
	state.focus_widget = "setup"
	core.harness_run = {status = .Running}
	ui := core.Caller{kind = .UI}
	r := core.run_command(core.Set_Focus{widget = "settings"}, ui)
	testing.expectf(t, !r.ok && state.focus_widget == "setup", "⌘, : %v", r.error)
	r = core.run_command(core.Set_Focus{widget = ""}, ui)
	testing.expect(t, !r.ok && state.focus_widget == "setup")
	r = core.run_command(core.Setup_Sheet{open = false}, ui)
	testing.expect(t, !r.ok && state.focus_widget == "setup", "the sheet does not close")
	r = core.run_command(core.Job_Sheet{open = true}, ui)
	testing.expect(t, !r.ok && !job_sheet_open() && state.focus_widget == "setup", "no job sheet over it")
	// anything else that moved it: back on the sheet's next frame, on the run's step
	state.focus_widget = "agent_input"
	setup_ui.step = 2
	harness_run_keep_sheet()
	testing.expect_value(t, state.focus_widget, "setup")
	testing.expect_value(t, setup_step_kind(), core.Setup_Step.Agents)
	core.harness_run.status = .Done
	testing.expect(t, core.run_command(core.Set_Focus{widget = ""}, ui).ok, "after the run")
	setup_ui.step = 0
}
