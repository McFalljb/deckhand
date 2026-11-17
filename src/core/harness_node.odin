package core

// Harnesses installed with npm under a Node version manager (harness.odin: harness_installed), read
// from disk only: nvm, fnm, Volta and node itself are never run.
//
//   - nvm loaded lazily (a .zshrc that defines `nvm`/`node` as functions that source nvm on first
//     use) puts nothing on PATH until a command runs, so neither the PATH new tabs get nor the
//     login shell's `command -v` finds a global `claude`/`codex`/`pi`. nvm_bin_dirs reads nvm's
//     folders: the default alias's version first ($NVM_DIR/alias/default: "22", "v22.3.0",
//     "lts/iron", "node"), then every installed version, newest first.
//   - fnm puts a per-shell folder on PATH (…/fnm_multishells/<id>/bin, a link to the version's
//     installation) that goes away with that shell: harness_installed caches the folder resolved
//     (harness_real_dir), and fnm_bin_dirs reads fnm's default alias and its versions.
//   - Volta's shims (~/.volta/bin/<name> -> volta-shim) say nothing about the version: volta_target
//     finds the package Volta installed (its image folder) for the version reading.

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The npm package of each harness (Volta's image folders are named by it).
HARNESS_NPM_PACKAGES := [Harness]string {
	.Pi     = PI_PACKAGE,
	.Claude = "@anthropic-ai/claude-code",
	.Codex  = "@openai/codex",
}

// "v22.3.0" or "22.3.0" -> {22, 3, 0}; ok = false for anything else.
@(private = "file")
node_version_parse :: proc(s: string) -> (v: [3]int, ok: bool) {
	t := strings.trim_prefix(s, "v")
	parts := strings.split(t, ".", context.temp_allocator)
	if len(parts) != 3 do return {}, false
	for p, i in parts {
		if p == "" || len(p) > 6 do return {}, false
		for c in transmute([]u8)p {
			if c < '0' || c > '9' do return {}, false
			v[i] = v[i] * 10 + int(c - '0')
		}
	}
	return v, true
}

// The version folders' names in dir that look like node versions, newest first (temp).
@(private = "file")
node_versions_in :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return out[:]
	for f in files do if _, ok := node_version_parse(f.name); ok do append(&out, f.name)
	slice.sort_by(out[:], proc(a, b: string) -> bool {
		x, _ := node_version_parse(a)
		y, _ := node_version_parse(b)
		for i in 0 ..< 3 do if x[i] != y[i] do return x[i] > y[i]
		return false
	})
	return out[:]
}

// Whether version name v ("v22.3.0") is what an alias asks for: exactly, or by its leading parts
// ("22", "v22.3"). "" = any (node, stable: the newest).
@(private = "file")
node_version_matches :: proc(v, want: string) -> bool {
	w := strings.trim_prefix(want, "v")
	if w == "" do return true
	t := strings.trim_prefix(v, "v")
	return t == w || strings.has_prefix(t, strings.concatenate({w, "."}, context.temp_allocator))
}

@(private = "file")
read_small :: proc(path: string) -> string {
	if k, st := path_stat(path); k != .File || st.size > 256 do return ""
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	return strings.trim_space(string(data))
}

// nvm's bin folders under nvm_dir: the default alias's version first, then every version, newest
// first (absolute nvm_dir only; temp). Aliases are followed a few hops (lts/* -> lts/iron ->
// v20.18.0); "system" means nvm is not in use.
nvm_bin_dirs :: proc(nvm_dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if !filepath.is_abs(nvm_dir) do return out[:]
	root := strings.trim_right(nvm_dir, "/")
	vroot := strings.concatenate({root, "/versions/node"}, context.temp_allocator)
	versions := node_versions_in(vroot)
	if len(versions) == 0 do return out[:]
	want := read_small(strings.concatenate({root, "/alias/default"}, context.temp_allocator))
	for _ in 0 ..< 4 {
		if want == "" || want == "node" || want == "stable" || want == "system" do break
		if _, ok := node_version_parse(want); ok do break
		next := read_small(strings.concatenate({root, "/alias/", want}, context.temp_allocator)) // lts/iron, lts/*, a user alias
		if next == "" do break
		want = next
	}
	if want != "system" {
		if want == "node" || want == "stable" do want = ""
		for v in versions do if node_version_matches(v, want) {
			append(&out, strings.concatenate({vroot, "/", v, "/bin"}, context.temp_allocator))
			break
		}
	}
	for v in versions {
		d := strings.concatenate({vroot, "/", v, "/bin"}, context.temp_allocator)
		if !slice.contains(out[:], d) do append(&out, d)
	}
	return out[:]
}

// fnm's bin folders under fnm_dir: its default alias (resolved: never a per-shell folder), then
// every installed version, newest first (absolute fnm_dir only; temp).
fnm_bin_dirs :: proc(fnm_dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if !filepath.is_abs(fnm_dir) do return out[:]
	root := strings.trim_right(fnm_dir, "/")
	if r := fs_real(strings.concatenate({root, "/aliases/default"}, context.temp_allocator)); r != "" && path_kind(r) == .Dir {
		append(&out, strings.concatenate({r, "/bin"}, context.temp_allocator))
	}
	vroot := strings.concatenate({root, "/node-versions"}, context.temp_allocator)
	for v in node_versions_in(vroot) {
		d := strings.concatenate({vroot, "/", v, "/installation/bin"}, context.temp_allocator)
		if r := fs_real(d); r != "" do d = r
		if !slice.contains(out[:], d) do append(&out, d)
	}
	return out[:]
}

// The Node version managers' bin folders to look in after the harness's own folders (temp): nvm's
// ($NVM_DIR, else ~/.nvm) and fnm's ($FNM_DIR, else ~/.local/share/fnm and
// ~/Library/Application Support/fnm). nvm_dir/fnm_dir: "" = the defaults under home.
node_manager_dirs :: proc(home, nvm_dir, fnm_dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	h := strings.trim_right(home, "/")
	abs_home := filepath.is_abs(h)
	nvm := nvm_dir
	if nvm == "" && abs_home do nvm = strings.concatenate({h, "/.nvm"}, context.temp_allocator)
	append(&out, ..nvm_bin_dirs(nvm))
	fnms := make([dynamic]string, context.temp_allocator)
	if fnm_dir != "" do append(&fnms, fnm_dir)
	else if abs_home do append(&fnms, strings.concatenate({h, "/.local/share/fnm"}, context.temp_allocator), strings.concatenate({h, "/Library/Application Support/fnm"}, context.temp_allocator))
	for f in fnms do append(&out, ..fnm_bin_dirs(f))
	return out[:]
}

// The folder of p with its links resolved, then p's name: a per-shell folder (fnm's multishell
// link) becomes the install it points to, which stays. "" stays "". Temp.
harness_real_dir :: proc(p: string) -> string {
	if !filepath.is_abs(p) do return p
	d := fs_real(filepath.dir(p))
	if d == "" do return p
	return strings.concatenate({d == "/" ? "" : d, "/", filepath.base(p)}, context.temp_allocator)
}

// For a Volta shim (bin links to <volta home>/bin/volta-shim): the package.json of the harness's
// package Volta installed (<volta home>/tools/image/packages/<package>/lib/node_modules/<package>),
// which the version readers take as the binary (its path names the package). Else bin itself. Read
// only, never run. Temp.
volta_target :: proc(h: Harness, bin: string) -> string {
	real := fs_real(bin)
	if real == "" || filepath.base(real) != "volta-shim" do return bin
	home := filepath.dir(filepath.dir(real)) // <volta home>/bin/volta-shim
	pkg := HARNESS_NPM_PACKAGES[h]
	for sub in ([]string{"/lib/node_modules/", "/node_modules/"}) {
		pj := strings.concatenate({home, "/tools/image/packages/", pkg, sub, pkg, "/package.json"}, context.temp_allocator)
		if path_kind(pj) == .File do return pj
	}
	return bin
}
