package main

// Deckhand's pi integration (integrations/pi, docs/HARNESSES.md): pi extensions Deckhand ships
// in the app and loads into every pi tab with `pi -e <path>`, as it loads its Claude Code plugin
// with --plugin-dir. Nothing is written to pi's settings.
//
//   - Where: DECKHAND_PI_INTEGRATION (test mode only: scenes), else the bundle's Contents/Resources/pi, else
//     pi next to the binary (a bare build). It must hold extensions.json.
//   - What: extensions.json lists the extensions in load order, each required or optional. Every
//     pi start (start_pi: new tabs, chats, Atlas, restores, restarts) gets one `-e
//     <dir>/extensions/<name>` per required one and per optional one turned on (pi_extension_on:
//     the user's choice in the Settings tab's "pi extensions" group, Set_Pi_Extension, else the
//     manifest's `default`). Jobs run `pi --mode json` and get none: the required parts are inert
//     there (each starts only in the interactive TUI) and the optional ones are the user's choice
//     for tabs.
//   - Optional extensions: guardrails, shell, notes (pi-kit's, bundled). A choice applies at a
//     tab's next start: each pi tab records which it started with (Tab.reload.extras,
//     pi_integration_extras), and one that differs from the choices now is outdated for the
//     restart bar (reload_outdated, ui_reload.odin: "pi extensions changed — Restart N idle tabs").
//   - Atlas also gets `--skill <dir>/skills/deckhand-desk` (pi_integration_atlas_args): Deckhand's
//     copy of pi-kit's desk skill, which the Atlas prompt names. pi 1.5.0 lists --skill paths after
//     the user's and packages' skills (resource-loader.js mergePaths(..., additionalSkillPaths))
//     and keeps the first skill of a name, so it has a name of its own: a same-named one would lose
//     to pi-kit's `desk`.
//   - Namespace: a pi tab's environment carries DECKHAND_SOCKET, DECKHAND_TOKEN and
//     DECKHAND_SHOTS_DIR (Atlas: also DECKHAND_CONTROL_TOKEN), never PI_DESK_SOCKET,
//     PI_DESK_TOKEN or PI_DESK_CONTROL_TOKEN: pi-kit's desk extensions switch on only with
//     those, so an installed pi-kit stays inert next to the bundled copy (socket_pi_env).
//   - Minimum pi: PI_MIN_VERSION. A pi known (state.reload.pi_version, read from its package
//     on disk, never run) to be older gets no -e; its tabs get a bar saying so (ui_claude.odin's
//     status bar), and so does the setup sheet. Unknown: loaded.

import "core:encoding/json"
import jg "jsonguard"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

PI_MIN_VERSION :: "1.4.0" // `-e` and the extension API the integration uses (docs/HARNESSES.md)
PI_UPDATE_COMMAND :: "pi update"

// Tests: the integration's folder instead of the bundle's.
pi_integration_override: string
// Tests: whether an optional extension is turned on, instead of pi_extension_on.
pi_integration_optional_on: proc(name: string) -> bool

// The user's choice for one optional extension (Settings.pi_extensions).
Pi_Extension_Choice :: struct {
	name: string,
	on:   bool,
}

// An optional extension of the manifest, for the Settings tab (temp-allocated strings).
Pi_Optional_Extension :: struct {
	name, does: string,
	default_on: bool,
	on:         bool, // turned on now (pi_extension_on)
}

// Set_Pi_Extension: turn one of the integration's optional extensions on or off for the pi tabs
// started from now on (user-only: what loads into every pi, guardrails among them).
Set_Pi_Extension :: struct {
	name: string,
	on:   bool,
}

// The skill Atlas gets (pi_integration_atlas_args); the Atlas prompt names it.
PI_ATLAS_SKILL :: "deckhand-desk"

@(private = "file")
Pi_Extension :: struct {
	name:       string,
	required:   bool,
	default_on: bool, // optional ones: on until the user chooses
	does:       string,
}

@(private = "file")
manifest_dir: string // the folder the cached manifest came from ("" = none read)
@(private = "file")
manifest: [dynamic]Pi_Extension

// Tests: read the manifest again.
pi_integration_forget :: proc() {
	for e in manifest {
		delete(e.name)
		delete(e.does)
	}
	clear(&manifest)
	delete(manifest_dir)
	manifest_dir = ""
}

// The integration's folder ("" = not in this build). Temp-allocated.
pi_integration_dir :: proc() -> string {
	ok :: proc(p: string) -> bool {return path_kind(fmt.tprintf("%s/extensions.json", p)) == .File}
	if pi_integration_override != "" do return ok(pi_integration_override) ? pi_integration_override : ""
	// unit tests: only the override (the test binary in build/ would find build/pi)
	when ODIN_TEST do return ""
	if p := pi_integration_from_env(test_mode()); p != "" do return p
	exe := executable_path()
	if exe == "" do return ""
	dir := filepath.dir(exe)
	for c in ([]string{"../Resources/pi", "pi"}) {
		p, _ := filepath.join({dir, c}, context.temp_allocator)
		if ok(p) do return p
	}
	return ""
}

// DECKHAND_PI_INTEGRATION's folder: in test mode only, absolute, holding extensions.json; else "".
// Test mode (DECKHAND_SCRIPT) is switched on by the environment too, so this is the same trust
// boundary as DECKHAND_CMD (the command a pi tab runs): whoever sets Deckhand's environment.
pi_integration_from_env :: proc(test: bool) -> string {
	if !test do return ""
	p := hook_env(.Pi_Integration)
	if p == "" || !filepath.is_abs(p) || path_kind(fmt.tprintf("%s/extensions.json", p)) != .File do return ""
	return p
}

// pi is known to be older than PI_MIN_VERSION (unknown or unparsable: false).
pi_too_old :: proc() -> bool {return pi_version_below(state.reload.pi_version)}

@(private = "file")
pi_version_below :: proc(v: string) -> bool {
	have, ok := semver_parse(v)
	if !ok do return false
	min, _ := semver_parse(PI_MIN_VERSION)
	return semver_less(have, min)
}

// The manifest of the integration in `dir` (read once per folder).
@(private = "file")
manifest_load :: proc(dir: string) {
	if dir != manifest_dir {
		pi_integration_forget()
		manifest_dir = strings.clone(dir)
		data, err := os.read_entire_file(fmt.tprintf("%s/extensions.json", dir), context.temp_allocator)
		if err == nil {
			Raw :: struct {
				extensions: []struct {
					name:       string,
					required:   bool,
					default_on: bool `json:"default"`,
					does:       string,
				},
			}
			raw: Raw
			if jg.unmarshal(data, &raw, .JSON, context.temp_allocator) == nil {
				for e in raw.extensions do append(&manifest, Pi_Extension{name = strings.clone(e.name), required = e.required, default_on = e.default_on, does = strings.clone(e.does)})
			} else do fmt.eprintln("Deckhand: the pi integration's extensions.json is not valid JSON")
		}
	}
}

// A manifest name that is a plain folder name.
@(private = "file")
plain_name :: proc(name: string) -> bool {
	return name != "" && name != "." && name != ".." && !strings.contains_any(name, "/\\")
}

// Whether an optional extension is turned on: the user's choice, else the manifest's default.
pi_extension_on :: proc(name: string) -> bool {
	if pi_integration_optional_on != nil do return pi_integration_optional_on(name)
	for c in state.settings.pi_extensions do if c.name == name do return c.on
	if dir := pi_integration_dir(); dir != "" {
		manifest_load(dir)
		for e in manifest do if e.name == name && !e.required do return e.default_on
	}
	return false
}

// The arguments every pi start gets before its own: `-e <dir>/extensions/<name>` per extension
// to load, in the manifest's order. None without the integration or on a pi known to be too old.
// A name that is not a plain folder name, or whose folder is missing, is left out. Temp-allocated.
pi_integration_args :: proc() -> []string {
	args, _ := integration_load_list()
	return args
}

// Which optional extensions a pi start loads now: bit i = the manifest's entry i (the same choices
// as pi_integration_args). A pi tab keeps the value it started with (Tab.reload.extras).
pi_integration_extras :: proc() -> u64 {
	_, extras := integration_load_list()
	return extras
}

@(private = "file")
integration_load_list :: proc() -> (args: []string, extras: u64) {
	if pi_too_old() do return nil, 0
	dir := pi_integration_dir()
	if dir == "" do return nil, 0
	manifest_load(dir)
	out := make([dynamic]string, context.temp_allocator)
	for e, i in manifest {
		if !plain_name(e.name) do continue
		if !e.required && !pi_extension_on(e.name) do continue
		p := fmt.tprintf("%s/extensions/%s", dir, e.name)
		if path_kind(p) != .Dir do continue
		append(&out, "-e", p)
		if !e.required && i < 64 do extras |= 1 << u64(i)
	}
	return out[:], extras
}

// A running pi tab started with other optional extensions than the user's choices now. The
// restart bar asks this for every pi tab on every frame: the value now is worked out once per frame
// and settings change (pi_integration_extras stats the integration's folders). Unit tests draw no
// frames (frames_called 0): no cache.
pi_extras_outdated :: proc(t: ^Tab) -> bool {
	@(static) cache: struct {
		frame, gen, value: u64,
	}
	if app_frames_called == 0 do return t.reload.extras != pi_integration_extras()
	if cache.frame != app_frames_called || cache.gen != settings_gen {
		cache = {frame = app_frames_called, gen = settings_gen, value = pi_integration_extras()}
	}
	return t.reload.extras != cache.value
}

// The manifest's optional extensions, in its order, for the Settings tab (none without the
// integration in this build). Temp-allocated.
pi_integration_optional :: proc() -> []Pi_Optional_Extension {
	dir := pi_integration_dir()
	if dir == "" do return nil
	manifest_load(dir)
	out := make([dynamic]Pi_Optional_Extension, context.temp_allocator)
	for e in manifest {
		if e.required || !plain_name(e.name) || path_kind(fmt.tprintf("%s/extensions/%s", dir, e.name)) != .Dir do continue
		append(&out, Pi_Optional_Extension{name = strings.clone(e.name, context.temp_allocator), does = strings.clone(e.does, context.temp_allocator), default_on = e.default_on, on = pi_extension_on(e.name)})
	}
	return out[:]
}

// Atlas's extra arguments from the integration: `--skill <dir>/skills/deckhand-desk` when it has that skill
// (and pi is new enough to load the integration at all). Temp-allocated.
pi_integration_atlas_args :: proc() -> []string {
	if pi_too_old() do return nil
	dir := pi_integration_dir()
	if dir == "" do return nil
	p := fmt.tprintf("%s/skills/%s", dir, PI_ATLAS_SKILL)
	if path_kind(fmt.tprintf("%s/SKILL.md", p)) != .File do return nil
	out := make([]string, 2, context.temp_allocator)
	out[0], out[1] = "--skill", p
	return out
}

// Set_Pi_Extension (commands.odin's apply hands it here).
pi_integration_apply :: proc(cmd: Command, caller: Caller) -> (Result, bool) {
	c, ok := cmd.(Set_Pi_Extension)
	if !ok do return fail("not a pi extension command"), false
	if !plain_name(c.name) do return fail("not an optional pi extension"), false
	// a saved choice coming back (persist) is kept as it is; the user's only for an optional
	// extension this build has
	if caller.kind != .Internal {
		known := false
		for e in pi_integration_optional() do if e.name == c.name do known = true
		if !known do return fail(fmt.tprintf("%q is not an optional pi extension of this Deckhand", c.name)), false
	}
	for &x in state.settings.pi_extensions {
		if x.name != c.name do continue
		if x.on == c.on do return {ok = true}, false
		x.on = c.on
		changed_pi_extensions()
		return {ok = true}, true
	}
	if len(state.settings.pi_extensions) >= 64 do return fail("too many pi extension choices"), false
	append(&state.settings.pi_extensions, Pi_Extension_Choice{name = strings.clone(c.name), on = c.on})
	changed_pi_extensions()
	return {ok = true}, true
}

@(private = "file")
changed_pi_extensions :: proc() {
	settings_gen += 1 // the Settings tab's rows
	state.reload.restart_dismissed = false // the restart bar offers the tabs that started otherwise
}

// ---- the version bar over a pi tab (drawn with the Claude tabs' status bar, ui_claude.odin) ----

@(private = "file")
pi_dismissed: string // the version whose bar the user dismissed (this run of Deckhand)

// Tests: nothing dismissed.
pi_status_reset :: proc() {
	delete(pi_dismissed)
	pi_dismissed = ""
}

// The bar over a running pi tab whose pi is older than PI_MIN_VERSION ("" = none).
pi_status_message :: proc(tab: ^Tab) -> string {
	if tab == nil || tab.status != .Running do return ""
	if _, is := tab.kind.(Pi_Tab); !is do return ""
	v := tab.reload.version
	if !pi_version_below(v) || v == pi_dismissed do return ""
	return fmt.tprintf("pi %s is older than %s, which Deckhand needs for its features in pi tabs (status, waits, comments, panels, Atlas's and the browser tools), so they don't work here. Update pi (%s, or the way you installed it), then restart the tab.", v, PI_MIN_VERSION, PI_UPDATE_COMMAND)
}

pi_status_dismiss :: proc(tab: ^Tab) {
	if tab == nil do return
	window_state_changed()
	delete(pi_dismissed)
	pi_dismissed = strings.clone(tab.reload.version)
}

// The setup sheet's sentence about an old pi ("" = none).
pi_setup_note :: proc() -> string {
	if !pi_too_old() do return ""
	return fmt.tprintf(" pi %s is older than %s, which Deckhand needs for its features in pi tabs: update it (%s).", state.reload.pi_version, PI_MIN_VERSION, PI_UPDATE_COMMAND)
}
