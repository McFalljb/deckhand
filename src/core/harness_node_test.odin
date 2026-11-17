package core

// Harnesses under Node version managers (harness_node.odin), on fake folder layouts: nvm loaded
// lazily, fnm's per-shell folder, Volta's shims. Nothing here is ever run but the fake tab
// scripts below (by /bin/sh, as a tab would).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
hn_dir :: proc(tag: string) -> string {
	d := fmt.tprintf("%s/deckhand-hn-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	return fs_real(d)
}

@(private = "file")
hn_write :: proc(path, text: string, exec := false) {
	os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	_ = os.write_entire_file(path, transmute([]u8)text)
	if exec do os.change_mode(path, os.perm_number(0o755))
}

@(private = "file")
hn_run :: proc(script, home: string) -> (out: string, code: int) {
	r, w, perr := os.pipe()
	if perr != nil do return "", -1
	defer os.close(r)
	p, err := os.process_start({command = {"/usr/bin/env", "-i", fmt.tprintf("HOME=%s", home), "PATH=/usr/bin:/bin", "/bin/sh", "-c", script, "x", "--arg"}, stdout = w, stderr = w})
	os.close(w)
	if err != nil do return "", -1
	data, _ := os.read_entire_file(r, context.temp_allocator)
	st, _ := os.process_wait(p)
	return string(data), st.exit_code
}

// nvm loaded lazily puts nothing on PATH: the binary is found in nvm's own folders, the default
// alias's version first (followed through lts/ aliases), else the newest that has it; and the tab
// starts it from there (its folder first on PATH: the node next to it too).
@(test)
nvm_lazy_found_on_disk :: proc(t: ^testing.T) {
	d := hn_dir("nvm")
	defer os.remove_all(d)
	nvm := fmt.tprintf("%s/.nvm", d)
	for v in ([]string{"v18.0.0", "v20.1.0", "v22.3.0"}) do os.make_directory_all(fmt.tprintf("%s/versions/node/%s/bin", nvm, v))
	os.make_directory_all(fmt.tprintf("%s/versions/node/not-a-version", nvm))
	for v in ([]string{"v20.1.0", "v22.3.0"}) do hn_write(fmt.tprintf("%s/versions/node/%s/bin/claude", nvm, v), fmt.tprintf("#!/bin/sh\necho FAKE NVM %s \"$@\"\n", v), exec = true)
	hn_write(fmt.tprintf("%s/versions/node/v18.0.0/bin/codex", nvm), "#!/bin/sh\nexit 1\n", exec = true)
	bin :: proc(nvm, v, name: string) -> string {return fmt.tprintf("%s/versions/node/%s/bin/%s", nvm, v, name)}
	nohome := fmt.tprintf("%s/nohome", d)

	// no default alias: the newest
	testing.expect_value(t, harness_find(.Claude, "", nohome, "", nvm_bin_dirs(nvm)), bin(nvm, "v22.3.0", "claude"))
	// a major version
	hn_write(fmt.tprintf("%s/alias/default", nvm), "20\n")
	testing.expect_value(t, harness_find(.Claude, "", nohome, "", nvm_bin_dirs(nvm)), bin(nvm, "v20.1.0", "claude"))
	// lts/* -> lts/iron -> v22.3.0
	hn_write(fmt.tprintf("%s/alias/lts/iron", nvm), "v22.3.0\n")
	hn_write(fmt.tprintf("%s/alias/lts/*", nvm), "lts/iron\n")
	hn_write(fmt.tprintf("%s/alias/default", nvm), "lts/*\n")
	testing.expect_value(t, harness_find(.Claude, "", nohome, "", nvm_bin_dirs(nvm)), bin(nvm, "v22.3.0", "claude"))
	// the default's version lacks it: another version that has it
	testing.expect_value(t, harness_find(.Codex, "", nohome, "", nvm_bin_dirs(nvm)), bin(nvm, "v18.0.0", "codex"))
	// PATH still comes first
	other := fmt.tprintf("%s/other", d)
	hn_write(fmt.tprintf("%s/claude", other), "#!/bin/sh\nexit 1\n", exec = true)
	testing.expect_value(t, harness_find(.Claude, other, nohome, "", nvm_bin_dirs(nvm)), fmt.tprintf("%s/claude", other))
	// ~/.nvm by default; no nvm: nothing
	testing.expect_value(t, harness_find(.Claude, "", d, "", node_manager_dirs(d, "", "")), bin(nvm, "v22.3.0", "claude"))
	testing.expect_value(t, len(nvm_bin_dirs(fmt.tprintf("%s/none", d))), 0)
	testing.expect_value(t, len(nvm_bin_dirs("relative/.nvm")), 0)

	// the tab: not on its PATH; told the folder, it starts that claude
	empty := fmt.tprintf("%s/emptyhome", d)
	os.make_directory_all(empty)
	out, code := hn_run(CLAUDE_TAB_CMD, empty)
	testing.expect_value(t, code, 127)
	dir := fmt.tprintf("%s/versions/node/v22.3.0/bin", nvm)
	out, code = hn_run(strings.concatenate({"_dh_found=", sh_quote(dir), "; ", CLAUDE_TAB_CMD}), empty)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "FAKE NVM v22.3.0 --arg"), out)
	testing.expect(t, strings.contains(out, "where Deckhand found it"), out)
	// a folder without it changes nothing
	out, code = hn_run(strings.concatenate({"_dh_found=", sh_quote(other), "x; ", CLAUDE_TAB_CMD}), empty)
	testing.expect_value(t, code, 127)
	// the same step for pi and Codex
	hn_write(fmt.tprintf("%s/codex", dir), "#!/bin/sh\necho FAKE CODEX \"$@\"\n", exec = true)
	out, code = hn_run(strings.concatenate({"_dh_found=", sh_quote(dir), "; ", CODEX_TAB_CMD}), empty)
	testing.expect(t, code == 0 && strings.contains(out, "FAKE CODEX --arg"), out)
	hn_write(fmt.tprintf("%s/pi", dir), "#!/bin/sh\necho FAKE PI \"$@\"\n", exec = true)
	out, code = hn_run(strings.concatenate({"_dh_found=", sh_quote(dir), "; ", PI_TAB_CMD}), empty)
	testing.expect(t, code == 0 && strings.contains(out, "FAKE PI --arg"), out)
}

// fnm's per-shell folder (fnm_multishells/<id>, a link to the version's installation) goes away
// with its shell: what is cached is the installation it points to; fnm's default alias and
// versions are read from disk too.
@(test)
fnm_multishell_resolved :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // harness_found / harness_where are global state
	d := hn_dir("fnm")
	defer os.remove_all(d)
	fnm := fmt.tprintf("%s/fnm", d)
	inst := fmt.tprintf("%s/node-versions/v22.0.0/installation", fnm)
	hn_write(fmt.tprintf("%s/bin/claude", inst), "#!/bin/sh\nexit 1\n", exec = true)
	os.make_directory_all(fmt.tprintf("%s/node-versions/v20.0.0/installation/bin", fnm))
	os.make_directory_all(fmt.tprintf("%s/aliases", fnm))
	_ = os.symlink(inst, fmt.tprintf("%s/aliases/default", fnm))
	shells := fmt.tprintf("%s/fnm_multishells", d)
	os.make_directory_all(shells)
	multi := fmt.tprintf("%s/123_456", shells)
	_ = os.symlink(inst, multi)

	dirs := fnm_bin_dirs(fnm)
	testing.expect(t, len(dirs) >= 1)
	if len(dirs) >= 1 do testing.expect_value(t, dirs[0], fmt.tprintf("%s/bin", inst))
	testing.expect_value(t, harness_find(.Claude, "", fmt.tprintf("%s/nohome", d), "", dirs), fmt.tprintf("%s/bin/claude", inst))
	testing.expect_value(t, harness_real_dir(fmt.tprintf("%s/bin/claude", multi)), fmt.tprintf("%s/bin/claude", inst))
	testing.expect_value(t, harness_real_dir(""), "")

	// found on a PATH that has the per-shell folder: the install is what is kept
	old_path := strings.clone(os.get_env("PATH", context.temp_allocator))
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	old_cbin := strings.clone(os.get_env("DECKHAND_CLAUDE_BIN", context.temp_allocator))
	defer {
		os.set_env("PATH", old_path)
		os.set_env("HOME", old_home)
		os.set_env("DECKHAND_CLAUDE_BIN", old_cbin)
		harness_recheck(.Claude)
	}
	os.unset_env("DECKHAND_CLAUDE_BIN")
	os.set_env("HOME", fmt.tprintf("%s/nohome", d))
	os.set_env("PATH", fmt.tprintf("%s/bin:/usr/bin:/bin", multi))
	harness_installed_probe[.Claude] = nil
	harness_recheck(.Claude)
	path, ok := harness_installed(.Claude)
	testing.expect(t, ok)
	testing.expect_value(t, path, fmt.tprintf("%s/bin/claude", inst))
	os.remove(multi) // the shell ended
	testing.expect_value(t, path_kind(path), Path_Kind.File)
	testing.expect_value(t, harness_found_sh(.Claude), fmt.tprintf("_dh_found='%s/bin'; ", inst))
}

// Volta's shims (~/.volta/bin/<name> -> volta-shim) are read through the package Volta installed
// (its image folder): a version, so the update bar and minimum checks work. No image: no version,
// and the shim is never run for one.
@(test)
volta_shim_versions :: proc(t: ^testing.T) {
	d := hn_dir("volta")
	defer os.remove_all(d)
	volta := fmt.tprintf("%s/.volta", d)
	ran := fmt.tprintf("%s/shim-ran", d)
	hn_write(fmt.tprintf("%s/bin/volta-shim", volta), fmt.tprintf("#!/bin/sh\ntouch '%s'\n", ran), exec = true)
	for name in ([]string{"claude", "codex", "pi"}) do _ = os.symlink(fmt.tprintf("%s/bin/volta-shim", volta), fmt.tprintf("%s/bin/%s", volta, name))
	img :: proc(volta, pkg: string) -> string {return fmt.tprintf("%s/tools/image/packages/%s/lib/node_modules/%s", volta, pkg, pkg)}

	// no image yet: unknown, never run
	label, _ := claude_version_of(fmt.tprintf("%s/bin/claude", volta))
	testing.expect_value(t, label, "")
	testing.expect_value(t, codex_version_of(fmt.tprintf("%s/bin/codex", volta)), "")
	testing.expect_value(t, pi_package_of(fmt.tprintf("%s/bin/pi", volta)), "")

	hn_write(fmt.tprintf("%s/package.json", img(volta, "@anthropic-ai/claude-code")), `{"name":"@anthropic-ai/claude-code","version":"2.1.300"}`)
	hn_write(fmt.tprintf("%s/package.json", img(volta, "@openai/codex")), `{"name":"@openai/codex","version":"0.170.0"}`)
	hn_write(fmt.tprintf("%s/package.json", img(volta, PI_PACKAGE)), `{"name":"@earendil-works/pi-coding-agent","version":"1.5.0"}`)
	ident: string
	label, ident = claude_version_of(fmt.tprintf("%s/bin/claude", volta))
	testing.expect_value(t, label, "2.1.300")
	testing.expect_value(t, ident, "2.1.300")
	testing.expect_value(t, codex_version_of(fmt.tprintf("%s/bin/codex", volta)), "0.170.0")
	testing.expect_value(t, harness_version_of(.Pi, fmt.tprintf("%s/bin/pi", volta)), "1.5.0")
	testing.expect(t, path_kind(ran) == .Missing, "the shim was never run")
	// anything else is left as it was
	testing.expect_value(t, volta_target(.Claude, "/usr/bin/true"), "/usr/bin/true")
}
