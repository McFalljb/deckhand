package core

// Codex CLI tabs (docs/CODEX.md; phase 1 of issue #112). A Codex tab is a Claude tab record
// (Claude_Tab, Claude_Record) with `codex` set: it shares the Claude tab's machinery as it is (the
// token and its process check, OSC 7501 status, the hooks' claude.session / claude.turn reports,
// held prompts, the dead-tab bar, history rows, the bell and the attention counts). What differs
// is here: the command line, the hooks Deckhand passes per run (and trusts for that run only),
// the version rule, the sign-in check, the stricter rule for text Deckhand types into Codex's
// composer, and the words.
//
//   - The command: `codex --no-daemon -C <cwd> -c hooks.<Event>=[…] … -c hooks.state={…}`
//     (`codex resume <id> --no-daemon -C <cwd> …` to resume). --no-daemon is mandatory: without it
//     the TUI attaches to Codex's shared background server, whose hooks do not descend from the
//     tab's process, and the token's process check (socket.odin) refuses them. Deckhand itself adds
//     no -s, -a, -m, -p, `projects` or `notify`: the user's own Codex settings apply. The user's own
//     flags (codex_args_check: only flags known safe for a tab; never one that touches the hooks,
//     Deckhand's MCP server, the folder or the daemon) go before Deckhand's, which come last. Never
//     --dangerously-bypass-hook-trust (it would run every hook unreviewed, the repo's too).
//     Deckhand writes nothing under ~/.codex or any Codex home; it sets CODEX_HOME only for a
//     tab of an account the user added (claude_accounts.odin with codex; docs/CODEX.md §6a).
//   - The hooks: the bundled CLI by its absolute path (`'<cli>' hook codex-<event>`), each with a
//     trusted_hash for this run in an inline `hooks.state` table (Codex 0.167.2's recipe:
//     codex_hook_hash). Other hooks (the user's, a repo's) keep their own trust. When the recipe
//     no longer matches a newer Codex, Codex shows its "Hooks need review" dialog and the hooks do
//     not run until the user answers it: status still comes from OSC 7501, and the "hooks silent"
//     bar says what is missing.
//   - Codex starts its session lazily: SessionStart (and so the session id, the row, resume) comes
//     with the first prompt. Before it the tab works on OSC 7501 alone.
//   - Values in -c are TOML (codex_toml_string). Only Deckhand's own text goes into them (the CLI's
//     path and fixed words); the cwd is its own argv element (-C), never TOML.

import "base:runtime"
import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

CODEX_MIN_VERSION :: "0.163.0" // OSC 7501 program status (and --no-daemon, 0.157)
// The oldest Codex a tab starts at all (--no-daemon): from it up to CODEX_MIN_VERSION, as a plain tab
// (codex_plain_version): `codex --no-daemon -C <cwd>` and the user's flags, no hooks, no MCP server,
// no token, nothing typed into it by Deckhand, and a bar saying so (as an old pi starts without the
// integration).
CODEX_PLAIN_MIN_VERSION :: "0.157.0"
CODEX_PLAIN_REFUSAL :: "this Codex is older than " + CODEX_MIN_VERSION + ": its tab runs without Deckhand's hooks and status, so Deckhand types nothing into it (update Codex, then Restart)"
CODEX_HASH_PINNED :: "0.167.2" // the Codex whose hook-trust recipe codex_hook_hash follows (codex_test.odin)
CODEX_INSTALL_COMMAND :: "npm install -g @openai/codex@latest"
CODEX_MISSING :: "Codex is not installed: install it with `" + CODEX_INSTALL_COMMAND + "`, then use Refresh shell environment or restart Deckhand"
CODEX_MISSING_NOTE :: " — Codex not installed"
CODEX_HOOK_TIMEOUT :: 10 // seconds (part of the trust hash); the CLI gives up sooner: UserPromptSubmit's hello and three calls take at most 7.5 s (tools/deckhand-cli/hooks.odin CODEX_HOOK_CALL_MS), the others' one call 8 s
CODEX_REMOTE :: "its Deckhand is too old to start Codex tabs: update Deckhand there (Update in its row's menu in the sidebar), then try again" // after "on <machine>: " (machine_route.odin)

// One hook Deckhand passes to a Codex tab: Codex's event name (the -c key), its snake_case name
// (the trust key and the hash), and the CLI's `hook` argument.
Codex_Hook :: struct {
	event, key, arg: string,
}

// SessionEnd is not passed: it carries nothing Deckhand uses (the process's exit says the rest),
// and it runs when Codex quits.
CODEX_HOOKS := [?]Codex_Hook {
	{"SessionStart", "session_start", "codex-session-start"},
	{"UserPromptSubmit", "user_prompt_submit", "codex-prompt-submit"},
	{"PermissionRequest", "permission_request", "codex-permission"},
	{"Stop", "stop", "codex-stop"},
}

// codex, or why there is none: it is not on the login shell's PATH (npm's global bin).
CODEX_TAB_CMD :: HARNESS_FOUND_CODEX_SH + `command -v codex >/dev/null 2>&1 || { printf '%s\n' "Codex (codex) was not found on your login shell's PATH:" "  $PATH" "Install it with: npm install -g @openai/codex@latest (or add its folder to PATH in your shell's login profile, ~/.zprofile for zsh), then open a Codex tab again."; exit 127; }; exec codex "$@"`

// What a Codex tab runs: DECKHAND_CODEX_CMD (tests: a fake codex), else codex (CODEX_TAB_CMD); in
// test mode never the real codex.
codex_tab_cmd :: proc() -> string {
	if c := hook_env(.Codex_Cmd); c != "" do return c
	when TEST_HOOKS {
		if test_mode() {
			test_mode_refused("codex")
			return TEST_NO_CODEX_CMD
		}
	}
	return strings.concatenate({harness_found_sh(.Codex), CODEX_TAB_CMD}, context.temp_allocator)
}

when TEST_HOOKS {
	TEST_NO_CODEX_CMD :: `printf '%s\n' "Deckhand test mode: no DECKHAND_CODEX_CMD; refusing to run the real codex"; exit 127`
}

// A Codex session id as Codex makes them: a UUID, 8-4-4-4-12 hex digits (it goes into argv after
// `resume`, where anything else would be taken for a session name).
codex_id_ok :: proc(id: string) -> bool {
	if len(id) != 36 do return false
	for i in 0 ..< 36 {
		c := id[i]
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' do return false
			continue
		}
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') do return false
	}
	return true
}

// The tab's kind of id: a Codex tab's must be a UUID, a Claude tab's claude_id_ok.
claude_tab_id_ok :: proc(ct: ^Claude_Tab, id: string) -> bool {
	return ct.codex ? codex_id_ok(id) : claude_id_ok(id)
}

// ---- the command line ----

// s as a TOML basic string, quotes included (temp): `"` and `\` escaped, control characters as
// \b \t \n \f \r or \uXXXX. ok false: s is not valid UTF-8 (TOML needs it; nothing goes then).
codex_toml_string :: proc(s: string) -> (out: string, ok: bool) {
	if !utf8.valid_string(s) do return "", false
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\b': strings.write_string(&b, `\b`)
		case '\t': strings.write_string(&b, `\t`)
		case '\n': strings.write_string(&b, `\n`)
		case '\f': strings.write_string(&b, `\f`)
		case '\r': strings.write_string(&b, `\r`)
		case:
			if c < 0x20 || c == 0x7f do fmt.sbprintf(&b, `\u%04X`, c)
			else do strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b), true
}

// s as JSON, the way Codex's hash input writes it (serde_json, compact): `"` and `\` escaped,
// control characters as \b \f \n \r \t or \u00xx, everything else as it is.
@(private = "file")
json_exact :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\b': strings.write_string(b, `\b`)
		case '\f': strings.write_string(b, `\f`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:
			if c < 0x20 do fmt.sbprintf(b, `\u%04x`, c)
			else do strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

// A hook's trust hash as Codex 0.167.2 computes it ("sha256:<hex>", temp): sha256 over the compact,
// key-sorted JSON of {event_name, hooks: [the handler, normalised]} (no matcher: Deckhand's hooks
// have none). The handler: type command, the command, async false, the timeout (always present
// after Codex's normalisation). A newer Codex may change the recipe: codex_test.odin pins a vector.
codex_hook_hash :: proc(event_key, command: string, timeout: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"event_name":`)
	json_exact(&b, event_key)
	strings.write_string(&b, `,"hooks":[{"async":false,"command":`)
	json_exact(&b, command)
	strings.write_string(&b, `,"timeout":`)
	strings.write_string(&b, fmt.tprint(timeout))
	strings.write_string(&b, `,"type":"command"}]}`)
	sum: [sha2.DIGEST_SIZE_256]u8
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)strings.to_string(b))
	sha2.final(&ctx, sum[:])
	out := strings.builder_make(context.temp_allocator)
	strings.write_string(&out, "sha256:")
	for x in sum do fmt.sbprintf(&out, "%02x", x)
	return strings.to_string(out)
}

// The shell command of a Codex hook (Codex runs it with sh -c): the CLI by its absolute path in
// single quotes, then `hook <arg>` (temp).
codex_hook_command :: proc(cli, arg: string) -> string {
	return strings.concatenate({sh_quote(cli), " hook ", arg}, context.temp_allocator)
}

// The -c values for Deckhand's hooks and their trust for this run (temp), or why there are none:
// the CLI's path must be absolute, valid UTF-8 and free of control characters (it goes into a sh
// command inside a TOML string).
codex_hook_overrides :: proc(cli: string) -> (out: []string, why: string) {
	if cli == "" || !filepath.is_abs(cli) do return nil, "Deckhand's command (deckhand-cli) is missing from this build: rebuild Deckhand"
	for i in 0 ..< len(cli) do if cli[i] < 0x20 || cli[i] == 0x7f do return nil, "the path of Deckhand's command has control characters"
	list := make([dynamic]string, context.temp_allocator)
	state := strings.builder_make(context.temp_allocator)
	strings.write_string(&state, "hooks.state={")
	for h, i in CODEX_HOOKS {
		cmd := codex_hook_command(cli, h.arg)
		q, ok := codex_toml_string(cmd)
		if !ok do return nil, "the path of Deckhand's command is not valid UTF-8"
		// (no fmt for these: its format strings take { and } as its own)
		timeout := fmt.tprint(CODEX_HOOK_TIMEOUT)
		append(&list, "-c", strings.concatenate({"hooks.", h.event, `=[{hooks=[{type="command",command=`, q, ",timeout=", timeout, "}]}]"}, context.temp_allocator))
		key, _ := codex_toml_string(strings.concatenate({"/<session-flags>/config.toml:", h.key, ":0:0"}, context.temp_allocator))
		hash, _ := codex_toml_string(codex_hook_hash(h.key, cmd, CODEX_HOOK_TIMEOUT))
		if i > 0 do strings.write_byte(&state, ',')
		strings.write_string(&state, key)
		strings.write_string(&state, "={trusted_hash=")
		strings.write_string(&state, hash)
		strings.write_byte(&state, '}')
	}
	strings.write_byte(&state, '}')
	append(&list, "-c", strings.to_string(state))
	return list[:], ""
}

// What follows `codex` in a Codex tab's argv (temp): a new conversation `<user> --no-daemon -C <cwd>
// <hooks>`, a resume `resume <id> <user> --no-daemon -C <cwd> <hooks>`. user: the user's flags, which
// passed codex_args_check; Deckhand's come after them (its -c last: Codex applies -c in order). why:
// none can start (a resume id that is not a UUID, a cwd that is not absolute, a CLI path that
// cannot go into TOML, a refused flag).
codex_args :: proc(cli, cwd, resume: string, user: []string = nil) -> (args: []string, why: string) {
	if !filepath.is_abs(cwd) do return nil, "the tab's folder is not an absolute path"
	if resume != "" && !codex_id_ok(resume) do return nil, "not a Codex session id"
	if e := codex_args_check(user); e != "" do return nil, e
	hooks, herr := codex_hook_overrides(cli)
	if herr != "" do return nil, herr
	out := make([dynamic]string, context.temp_allocator)
	if resume != "" do append(&out, "resume", resume)
	append(&out, ..user)
	append(&out, "--no-daemon", "-C", cwd)
	append(&out, ..hooks)
	append(&out, "-c", codex_mcp_override(cli))
	return out[:], ""
}

// The variables Codex passes to Deckhand's MCP server (env_vars: by name, from the tab's
// environment; never a value on the command line, which `ps` shows).
CODEX_MCP_ENV := [?]string{"DECKHAND_SOCKET", "DECKHAND_CLAUDE_TOKEN", "DECKHAND_SHOTS_DIR"}

// Deckhand's tools for this run (temp): the CLI's `mcp` as a stdio MCP server, one inline table (it
// replaces a `deckhand` server of the user's own for the run, never merges with it). cli: checked by
// codex_hook_overrides. Codex runs it outside its sandbox, as its own child: the token's process
// check (socket.odin) holds, and its authority is the tab's, as the `deckhand` command's is in a
// Claude tab.
codex_mcp_override :: proc(cli: string) -> string {
	q, _ := codex_toml_string(cli)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "mcp_servers.deckhand={command=")
	strings.write_string(&b, q)
	strings.write_string(&b, `,args=["mcp"],env_vars=[`)
	for v, i in CODEX_MCP_ENV {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, strings.concatenate({`"`, v, `"`}, context.temp_allocator))
	}
	strings.write_string(&b, "],tool_timeout_sec=620}") // Codex gives a tool 60 s: an app call may take 600, an upload waits 120 for the user
	return strings.to_string(b)
}

// ---- the user's flags ----

// A Codex flag the user may add to a tab (codex --help, 0.167.2): its long name, its short letter,
// whether it takes a value. Anything else is refused (an allowlist: a flag Codex adds later is
// refused until it is looked at).
@(private = "file")
Codex_Flag :: struct {
	long:  string,
	short: u8,
	value: bool,
}

@(private = "file")
CODEX_FLAGS_OK := [?]Codex_Flag {
	{"--model", 'm', true},
	{"--sandbox", 's', true},
	{"--ask-for-approval", 'a', true},
	{"--config", 'c', true}, // its key is checked (codex_config_refused)
	{"--add-dir", 0, true},
	{"--local-provider", 0, true},
	{"--oss", 0, false},
	{"--search", 0, false},
	{"--no-alt-screen", 0, false},
	{"--strict-config", 0, false},
	{"--approve-for-me", 0, false},
	{"--profile", 'p', true}, // a plain name (codex_profile_ok): $CODEX_HOME/<name>.config.toml over the base config, under every -c (Deckhand's too)
	{"--dangerously-bypass-approvals-and-sandbox", 0, false},
}

// A Codex flag's long name ("-m" → "--model"); one it does not know, as it is (harness_flags.odin).
codex_flag_long :: proc(name: string) -> string {
	if len(name) == 2 && name[0] == '-' do for f in CODEX_FLAGS_OK do if f.short == name[1] do return f.long
	return name
}

// Codex flags refused by name, and why (the others not in CODEX_FLAGS_OK: "not one Deckhand passes").
@(private = "file")
CODEX_FLAGS_REFUSED := [?]struct {
	long:  string,
	short: u8,
	why:   string,
} {
	{"--no-daemon", 0, "Deckhand sets it (its hooks must run under the tab's own Codex)"},
	{"--cd", 'C', "Deckhand sets the tab's folder"},
	{"--worktree", 0, "it moves the session to another folder than the tab's"},
	{"--dangerously-bypass-hook-trust", 0, "it would run every hook unreviewed, a repository's too"},
	{"--remote", 0, "the tab runs its own Codex: Deckhand's hooks and token check need it"},
	{"--remote-auth-token-env", 0, "the tab runs its own Codex: Deckhand's hooks and token check need it"},
	{"--last", 0, "Deckhand picks the conversation"},
	{"--all", 0, "Deckhand picks the conversation"},
	{"--include-non-interactive", 0, "Deckhand picks the conversation"},
	{"--image", 'i', "a Codex tab starts without a prompt"},
	{"--enable", 0, CODEX_FEATURES_WHY},
	{"--disable", 0, CODEX_FEATURES_WHY},
	{"--help", 'h', "it prints and exits"},
	{"--version", 'V', "it prints and exits"},
}

CODEX_NOT_A_FLAG :: "an argument that is not a flag: Codex would take it for a command or a prompt"
CODEX_FEATURES_WHY :: "Codex features are set in your ~/.codex/config.toml, not per tab"
CODEX_PROFILES_WHY :: "choose a profile with -p NAME (Codex no longer reads -c profile)"
CODEX_PROFILE_NAME_WHY :: "--profile takes a plain profile name (letters, digits, _, - and ., not starting with - or .)"

// A profile name Codex reads as $CODEX_HOME/<name>.config.toml and nothing else: letters, digits,
// _, - and ., not starting with - or . (no path: Codex refuses -p ../x itself; an unknown name is
// silently ignored).
codex_profile_ok :: proc(name: string) -> bool {
	if name == "" || len(name) > 128 || name[0] == '-' || name[0] == '.' do return false
	for ch in transmute([]u8)name do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_' || ch == '-' || ch == '.') do return false
	return true
}

// Why a -c key=value cannot go ("" = it can): nothing under `hooks` (Deckhand's hooks and their
// trust), `mcp_servers.deckhand` or the whole `mcp_servers` table (Deckhand's tools), `features`
// (any: some turn hooks off or change the daemon or MCP; Codex adds and renames them), `profile`
// or `profiles` (a profile's place against Deckhand's -c is unchecked). The key as Codex reads it:
// before the first `=`, a dotted path (quotes and spaces around a part ignored).
@(private = "file")
codex_config_refused :: proc(kv: string) -> string {
	key, eq, _ := strings.partition(kv, "=")
	if eq == "" || strings.trim_space(key) == "" do return "-c takes key=value"
	parts := strings.split(strings.trim_space(key), ".", context.temp_allocator)
	for &part in parts do part = strings.trim(strings.trim_space(part), `"'`)
	first := parts[0]
	second := len(parts) > 1 ? parts[1] : ""
	if first == "hooks" do return "-c hooks… would change Deckhand's hooks or their trust"
	if first == "mcp_servers" && (len(parts) == 1 || second == "deckhand") do return "-c mcp_servers.deckhand is Deckhand's own MCP server"
	if first == "features" do return "-c features… is refused: " + CODEX_FEATURES_WHY
	if first == "profile" || first == "profiles" do return "-c profile… is refused: " + CODEX_PROFILES_WHY
	return ""
}

// Why these flags of the user's cannot go to a Codex tab ("" = they can): at most CLAUDE_ARGS_MAX;
// no empty, long or multi-line one; flags only (a word that is not a flag's value would be a Codex
// subcommand, `codex exec`, or a prompt); only CODEX_FLAGS_OK, each value-taking one with its value
// (`-m o3`, `-mo3`, `--model=o3`; a separate value never starts with `-`, as Codex reads it); no
// -c of Deckhand's (codex_config_refused), no --disable hooks.
codex_args_check :: proc(args: []string) -> string {
	if len(args) > CLAUDE_ARGS_MAX do return fmt.tprintf("at most %d extra flags", CLAUDE_ARGS_MAX)
	for a in args do if a == "" || len(a) > 1024 || strings.contains_any(a, "\x00\r\n") do return "an extra flag is empty, too long or has a line break"
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if len(a) < 2 || a[0] != '-' || a == "--" do return CODEX_NOT_A_FLAG
		name, val: string
		has_val := false
		if a[1] == '-' {
			n, eq, v := strings.partition(a, "=")
			name, val, has_val = n, v, eq != ""
		} else {
			name = a[:2]
			if len(a) > 2 do val, has_val = strings.trim_prefix(a[2:], "="), true
		}
		flag: Maybe(Codex_Flag)
		for f in CODEX_FLAGS_OK do if name == f.long || (f.short != 0 && len(name) == 2 && name[1] == f.short) do flag = f
		f, ok := flag.?
		if !ok {
			for r in CODEX_FLAGS_REFUSED do if name == r.long || (r.short != 0 && len(name) == 2 && name[1] == r.short) do return fmt.tprintf("%s is refused: %s", flag_shown(name), r.why)
			return fmt.tprintf("%s is not a Codex flag Deckhand passes on", flag_shown(name))
		}
		if !f.value {
			if has_val do return fmt.tprintf("%s takes no value", f.long)
			continue
		}
		if !has_val {
			if i + 1 >= len(args) || strings.has_prefix(args[i + 1], "-") do return fmt.tprintf("%s needs a value", f.long)
			i += 1
			val = args[i]
		}
		if f.long == "--config" do if e := codex_config_refused(val); e != "" do return e
		if f.long == "--profile" && !codex_profile_ok(val) do return CODEX_PROFILE_NAME_WHY
	}
	return ""
}

// Whether args (passed codex_args_check) choose how Codex asks or sandboxes: -s, -a,
// --approve-for-me, full access itself, or a -c of approval_policy, sandbox_mode or
// sandbox_workspace_write.
@(private = "file")
codex_args_choose_access :: proc(args: []string) -> bool {
	for a, i in args {
		if len(a) < 2 || a[0] != '-' do continue
		kv := ""
		if a[1] == '-' {
			n, _, v := strings.partition(a, "=")
			switch n {
			case "--sandbox", "--ask-for-approval", "--approve-for-me", "--dangerously-bypass-approvals-and-sandbox": return true
			case "--config": kv = v != "" ? v : (i + 1 < len(args) ? args[i + 1] : "")
			}
		} else {
			switch a[1] {
			case 's', 'a': return true
			case 'c': kv = len(a) > 2 ? strings.trim_prefix(a[2:], "=") : (i + 1 < len(args) ? args[i + 1] : "")
			}
		}
		if kv == "" do continue
		key, _, _ := strings.partition(kv, "=")
		first, _, _ := strings.partition(strings.trim_space(key), ".")
		switch strings.trim(strings.trim_space(first), `"'`) {
		case "approval_policy", "sandbox_mode", "sandbox_workspace_write": return true
		}
	}
	return false
}

// What turning full access on asks the user (Set_Claude_Default_Flags with harness codex).
CODEX_FULL_ACCESS_CONFIRM :: "Start the Codex tabs you start with --dangerously-bypass-approvals-and-sandbox? Codex will edit files and run commands without asking you first, outside its sandbox. Agents' tabs never get it."

// args with the user's default Codex flags as the setting is NOW (codex_start, for a start the
// user makes; never saved into a tab's or a record's flags): the Default flags line before them
// (harness_with_defaults), then full access (--dangerously-bypass-approvals-and-sandbox), left
// out when the flags already choose how Codex asks or sandboxes (codex_args_choose_access; Codex
// refuses it beside -a or --approve-for-me), or past CLAUDE_ARGS_MAX. Temp.
codex_with_defaults :: proc(args_in: []string) -> []string {
	args := harness_with_defaults(.Codex, args_in)
	if !state.settings.codex_full_access || len(args) + 1 > CLAUDE_ARGS_MAX || codex_args_choose_access(args) do return args
	list := make([dynamic]string, 0, len(args) + 1, context.temp_allocator)
	append(&list, ..args)
	append(&list, "--dangerously-bypass-approvals-and-sandbox")
	return list[:]
}

// Starts codex in the tab's terminal (claude_start for a Codex tab): the login shell, CODEX_TAB_CMD
// and codex_args; the environment of a Claude tab (the socket, the tab's token, the CLI's path).
// flags: the tab's own flags (an agent's restart starts without them); defaults: a start the user
// makes, with the default flags as set now (codex_with_defaults). Its account: CODEX_HOME for a
// home the user added (none for the default), set again after the login profile.
codex_start :: proc(s: ^Open_Session, t: ^Term, tab_id: u64, ct: ^Claude_Tab, cwd: string, flags := true, defaults := false) -> (ok: bool, why: string) {
	bin := harness_path(.Codex) // by stat, else what the login shell named
	codex_plain_forget(tab_id)
	plain := ""
	if v := codex_version_of(bin); claude_version_below(v, CODEX_MIN_VERSION) {
		hint := codex_update_hint(bin)
		if claude_version_below(v, CODEX_PLAIN_MIN_VERSION) { 	// no --no-daemon: not at all
			term_note(t, codex_old_text(v, hint))
			return false, fmt.tprintf("Codex %s is older than %s: update it %s", v, CODEX_PLAIN_MIN_VERSION, hint) // the refusal: short (a hub cuts it)
		}
		plain = v // no OSC 7501: a plain tab
	}
	// its account (claude_accounts.odin): only a configured one starts
	if ct.account != "" && !claude_account_known(ct.account, codex = true) {
		why = fmt.tprintf("This Codex tab's account (%s) is no longer in Settings → Codex accounts: add it again, then Restart.", path_tilde(ct.account))
		term_note(t, why)
		return false, why
	}
	cli := claude_cli_path()
	user := flags ? ct.args : nil
	if e := codex_args_check(user); e != "" { // a saved tab or entry: checked again at every start
		why = fmt.tprintf("Codex can't start with this tab's flags: %s.", e)
		term_note(t, why)
		return false, why
	}
	if defaults do user = codex_with_defaults(user)
	args: []string
	awhy: string
	if plain != "" do args, awhy = codex_plain_args(cwd, ct.session_id, user)
	else do args, awhy = codex_args(cli, cwd, ct.session_id, user)
	if awhy != "" {
		why = fmt.tprintf("Codex can't start: %s.", awhy)
		term_note(t, why)
		return false, why
	}
	cmd := strings.concatenate({CODEX_ACCOUNT_SH, codex_tab_cmd()}, context.temp_allocator) // the account again after the login profile
	argv := shell_script_argv(login_shell(), cmd, "codex")
	append(&argv, ..args)
	env := make([dynamic]string, context.temp_allocator)
	// a plain tab gets no token: nothing of it may reach Deckhand (no hooks, no MCP server)
	if plain == "" do append(&env, ..pi_extra_env(socket_claude_env(tab_id, cli)))
	else {
		socket_forget_tab(tab_id) // a token of an earlier run of this tab dies too
		append(&env, ..pi_extra_env({}))
	}
	append(&env, ..claude_account_env(ct.account, codex = true)) // its account: CODEX_HOME (none for the default)
	start := Held_Start{kind = .Codex} // tokens.json: never adopted as a Claude tab
	if plain != "" do start.plain, _ = version_triple(plain) // and adopted plain again (holder_adopt)
	if !term_start(t, argv[:], cwd, env_with_legacy(env[:]), start) {
		socket_forget_tab(tab_id)
		return false, ""
	}
	claude_run_started(tab_id, t, ct)
	codex_login_check(ct.account)
	if plain != "" do codex_plain_set(tab_id, plain)
	return true, ""
}

// A plain Codex tab's command line (temp): the resume subcommand, the user's flags, then
// `--no-daemon -C <cwd>`; no hooks, no MCP server (CODEX_PLAIN_MIN_VERSION).
codex_plain_args :: proc(cwd, resume: string, user: []string = nil) -> (args: []string, why: string) {
	if !filepath.is_abs(cwd) do return nil, "the tab's folder is not an absolute path"
	if resume != "" && !codex_id_ok(resume) do return nil, "not a Codex session id"
	if e := codex_args_check(user); e != "" do return nil, e
	out := make([dynamic]string, context.temp_allocator)
	if resume != "" do append(&out, "resume", resume)
	append(&out, ..user)
	append(&out, "--no-daemon", "-C", cwd)
	return out[:], ""
}

// The running plain Codex tabs (codex_start): tab id -> its Codex's version (heap).
@(private = "file")
codex_plain: map[u64]string

@(private = "file")
codex_plain_set :: proc(tab_id: u64, v: string) {
	codex_plain_forget(tab_id)
	if codex_plain == nil do codex_plain = make(map[u64]string, runtime.heap_allocator())
	codex_plain[tab_id] = strings.clone(v, runtime.heap_allocator())
	window_state_changed()
}

// Forgets a tab's plain mark (a new start, its tab gone: claude_tab_gone).
codex_plain_forget :: proc(tab_id: u64) {
	if v, ok := codex_plain[tab_id]; ok {
		delete(v, runtime.heap_allocator())
		delete_key(&codex_plain, tab_id)
	}
}

// A Codex tab adopted from the session holder (holder_adopt) that tokens.json says was started
// plain (Held_Start.plain, its Codex's version): marked again, whatever its token trust and
// whatever codex is on disk now.
codex_plain_adopted :: proc(tab_id: u64, v: [3]u32) {
	codex_plain_set(tab_id, fmt.tprintf("%d.%d.%d", v[0], v[1], v[2]))
}

// The version of a running plain Codex tab's Codex ("" = not one).
codex_plain_version :: proc(tab_id: u64) -> string {
	v, _ := codex_plain[tab_id]
	return v
}

// The bar over a plain Codex tab (claude_status_message). hint: codex_update_hint's.
codex_plain_text :: proc(v, hint: string) -> string {
	return fmt.tprintf("Codex %s is older than %s: it runs here without Deckhand's hooks and status (no status mark, no row to resume, no held messages, comments or Deckhand's tools). Update it %s, then Restart the tab.", v, CODEX_MIN_VERSION, hint)
}

// ---- text Deckhand types into Codex's composer ----

// Why text cannot go into Codex's composer as a message ("" = it can). Stricter than Claude's
// (claude_command_text): a first / is a slash command, ! a shell command, $ a skill; an @word or
// $word anywhere a word starts opens Codex's mention popup (a pasted one was seen to); control
// characters other than tab and newline never go. A later line starting with / or ! is plain text
// (Codex reads a command only at the start of the composer). Unicode look-alikes (a fullwidth ／)
// are not checked: Codex does not read them as commands either.
codex_command_text :: proc(text: string) -> string {
	for i in 0 ..< len(text) {
		c := text[i]
		if (c < 0x20 && c != '\t' && c != '\n') || c == 0x7f do return "text has control characters (only tab and newline may go)"
	}
	lead := strings.trim_left(text, " \t\n")
	if lead != "" && strings.index_byte("/!$", lead[0]) >= 0 do return fmt.tprintf("text starting with %c would be a Codex command (/ slash command, ! shell, $ skill): Deckhand sends only messages", lead[0])
	for i in 0 ..< len(text) {
		c := text[i]
		if c != '@' && c != '$' do continue
		if i > 0 && !(text[i - 1] == ' ' || text[i - 1] == '\t' || text[i - 1] == '\n') do continue
		if i + 1 >= len(text) do continue
		n := text[i + 1]
		if c == '@' && !(n == ' ' || n == '\t' || n == '\n') do return "an @mention would open Codex's file or agent picker; send the name without @"
		if c == '$' && (n >= 'a' && n <= 'z' || n >= 'A' && n <= 'Z' || n == '_') do return "a $name would open Codex's skill picker; send the name without $"
	}
	return ""
}

// The rule for this tab's harness (claude_prompt, claude_paste_message).
claude_tab_command_text :: proc(ct: ^Claude_Tab, text: string) -> string {
	return ct.codex ? codex_command_text(text) : claude_command_text(text)
}

// ---- is Codex installed, which version, signed in? ----

// Whether Codex is installed, as new tabs would find it (harness_installed, harness.odin).
codex_installed :: proc() -> bool {
	_, found := harness_installed(.Codex)
	return found
}

// Looked up again (Refresh shell environment, a Codex tab that exited 127), its sign-in too.
codex_recheck :: proc() {
	harness_recheck(.Codex)
	for &x in codex_login {
		sync.atomic_add(&x.gen, 1)
		sync.atomic_store(&x.state, .Unknown)
	}
}

codex_installed_now :: proc() -> bool {return harness_installed_now(.Codex)}

// codex's version from where its binary links to: npm's package
// (<…>/node_modules/@openai/codex/bin/codex.js -> its package.json), Homebrew's cask
// (Caskroom/codex/<v>/); else, only then, from `codex --version` (codex_version_run). "" = unknown.
codex_version_of :: proc(bin: string) -> string {
	if bin == "" do return ""
	bin := volta_target(.Codex, bin) // a Volta shim: the package it runs (harness_node.odin)
	real := fs_real(bin)
	if real == "" do real = bin
	if i := strings.index(real, "/Caskroom/codex/"); i >= 0 {
		rest := real[i + len("/Caskroom/codex/"):]
		v, _, _ := strings.partition(rest, "/")
		return v
	}
	if strings.contains(real, "/node_modules/@openai/codex/") {
		dir := filepath.dir(real)
		for _ in 0 ..< 3 {
			pj := strings.concatenate({dir, "/package.json"}, context.temp_allocator)
			if path_kind(pj) == .File {
				v := pkg_version(pj)
				if v != "" do return v
			}
			dir = filepath.dir(dir)
		}
	}
	if v := codex_standalone_version(real); v != "" do return v
	if filepath.base(real) == "volta-shim" do return "" // a Volta shim whose package is not on disk: never run (it would run codex)
	return codex_version_run(real)
}

CODEX_STANDALONE_DIR :: "/packages/standalone/releases/" // under CODEX_HOME (~/.codex)
CODEX_STANDALONE_INSTALL_COMMAND :: "curl -fsSL https://chatgpt.com/codex/install.sh | sh" // openai/codex README

// Codex's own installer (scripts/install/install.sh in openai/codex, #135): ~/.local/bin/codex ->
// ~/.codex/packages/standalone/current/… -> releases/<version>-<target>/bin/codex, so the version
// is in the real path ("0.135.0-x86_64-unknown-linux-musl" -> 0.135.0; the installer's versions:
// x.y.z, -alpha[.N[.M]], -beta[.N]). Read from the path, never run. "" = not that layout.
codex_standalone_version :: proc(real: string) -> string {
	i := strings.index(real, CODEX_STANDALONE_DIR)
	if i < 0 do return ""
	seg, _, _ := strings.partition(real[i + len(CODEX_STANDALONE_DIR):], "/")
	n := 0
	for part in 0 ..< 3 { // x.y.z
		start := n
		for n < len(seg) && seg[n] >= '0' && seg[n] <= '9' do n += 1
		if n == start do return ""
		if part < 2 {
			if n >= len(seg) || seg[n] != '.' do return ""
			n += 1
		}
	}
	for pre in ([]string{"-alpha", "-beta"}) do if strings.has_prefix(seg[n:], pre) {
		n += len(pre)
		for n + 1 < len(seg) && seg[n] == '.' && seg[n + 1] >= '0' && seg[n + 1] <= '9' {
			n += 1
			for n < len(seg) && seg[n] >= '0' && seg[n] <= '9' do n += 1
		}
		break
	}
	if n < len(seg) && seg[n] != '-' do return ""
	return seg[:n]
}

// Any other install (Codex's installer before it kept releases: a plain ~/.local/bin/codex; #135):
// `<real> --version` run (argv, no shell, stdin /dev/null, 3 s at most: run_group), its last word
// ("codex-cli 0.46.0" -> 0.46.0) if it looks like a version. Codex writes its helper links under
// $CODEX_HOME/tmp/arg0 at every start, even for --version, and Deckhand never writes under
// ~/.codex: so it runs with CODEX_HOME at a new empty folder of ours (0700, in $TMPDIR), removed
// after. Once per binary: cached by its real path and stamp (main thread). "" = unknown.
@(private = "file")
codex_ran: struct {
	real:    string, // heap
	stamp:   Disk_Stamp,
	version: string, // heap
}

@(private = "file")
codex_version_run :: proc(real: string) -> string {
	k, st := path_stat(real)
	if k != .File || !exe_in(filepath.dir(real), filepath.base(real)) do return ""
	if codex_ran.real == real && codex_ran.stamp.mtime == st.mtime && codex_ran.stamp.size == st.size && codex_ran.stamp.inode == st.inode do return codex_ran.version
	home := codex_scratch_home()
	if home == "" do return "" // never with the real CODEX_HOME; asked again next time
	defer remove_tree(home)
	out, rs := run_group({"/usr/bin/env", strings.concatenate({"CODEX_HOME=", home}, context.temp_allocator), real, "--version"}, 3 * time.Second, cap = 4096)
	v := ""
	if rs == .Ok {
		line, _, _ := strings.partition(strings.trim_space(out), "\n")
		f := strings.fields(line, context.temp_allocator)
		if len(f) > 0 && codex_version_word(f[len(f) - 1]) do v = f[len(f) - 1]
	}
	heap := runtime.heap_allocator()
	delete(codex_ran.real, heap)
	delete(codex_ran.version, heap)
	codex_ran = {real = strings.clone(real, heap), stamp = st, version = strings.clone(v, heap)}
	return codex_ran.version
}

// A new empty 0700 folder for codex_version_run's CODEX_HOME ("" = none could be made). Temp.
@(private = "file")
codex_scratch_home :: proc() -> string {
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if !strings.has_prefix(tmp, "/") do tmp = "/tmp"
	tmpl := strings.clone_to_cstring(fmt.tprintf("%s/deckhand-codex-XXXXXX", tmp), context.temp_allocator)
	d := posix.mkdtemp(transmute([^]byte)tmpl)
	if d == nil do return ""
	return strings.clone(string(d), context.temp_allocator)
}

@(private = "file")
codex_version_word :: proc(v: string) -> bool {
	if v == "" || len(v) > 40 || v[0] < '0' || v[0] > '9' do return false
	for c in v do if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '.' || c == '-' || c == '+') do return false
	return true
}

// The version of the codex new tabs start ("" = unknown or none).
codex_version :: proc() -> string {return codex_version_of(harness_path(.Codex))}

// What a Codex too old for Deckhand says in the tab. hint: codex_update_hint's.
codex_old_text :: proc(v, hint: string) -> string {
	return fmt.tprintf("Codex %s is older than %s, the oldest Deckhand can start (it needs --no-daemon; %s for its status reports): update it %s, then open the tab again.", v, CODEX_PLAIN_MIN_VERSION, CODEX_MIN_VERSION, hint)
}

// How to update the codex at bin, for its install (install_layout): "with `<command>`" for npm,
// Homebrew, bun or pnpm (the bare command, as harness_update_bare names it); Codex's own installer
// run again for its standalone layout (never npm there); else the way it was installed. Temp.
codex_update_hint :: proc(bin: string) -> string {
	real := fs_real(bin)
	if real == "" do real = bin
	layout := install_layout(.Codex, real, "")
	if layout == .Managed do return fmt.tprintf("with Codex's own installer (`%s`)", CODEX_STANDALONE_INSTALL_COMMAND)
	if c := harness_update_bare(HARNESS_MANIFEST[harness_first_row(.Codex)], layout, real); c != "" do return fmt.tprintf("with `%s`", c)
	if bin == "" do return fmt.tprintf("with `%s`", CODEX_INSTALL_COMMAND)
	return "the way you installed it"
}

// Restart refused because codex is still not found (exit 127, codex_installed says no).
CODEX_MISSING_HINT :: "Codex is still not installed (or not on your login PATH): install it (`" + CODEX_INSTALL_COMMAND + "`), or add its folder to PATH in your shell's login profile, then press Restart"

// claude_installed_now or codex_installed_now, for the tab's harness.
claude_tab_installed_now :: proc(tab: ^Tab) -> bool {
	if ct, is := tab.kind.(Claude_Tab); is && ct.codex do return codex_installed_now()
	return claude_installed_now()
}

// Whether a tab is a Codex tab.
claude_tab_is_codex :: proc(tab: Tab) -> bool {
	ct, is := tab.kind.(Claude_Tab)
	return is && ct.codex
}

// A command that would start codex when it is not installed (as claude_missing).
codex_missing :: proc(caller: Caller) -> (r: Result, missing: bool) {
	if caller.kind == .UI ? codex_installed_now() : codex_installed() do return {}, false
	if caller.kind == .UI do window_toast(CODEX_MISSING, err = true)
	return fail(CODEX_MISSING), true
}

// A menu or palette label, with the note while Codex is not installed (temp).
codex_label :: proc(label: string) -> string {
	if codex_installed() do return label
	return strings.concatenate({label, CODEX_MISSING_NOTE}, context.temp_allocator)
}

// Signed in? `codex login status` (exit 1: signed out) under an account's home (CODEX_HOME, as its
// tabs get it), run once per recheck on a worker through the login shell (the PATH tabs get),
// after a Codex tab of that account started; its answer feeds the tab's bar (and the default's,
// the checklist). Only codex's exit status is used: its output is never read or kept.
Codex_Login :: enum i32 {
	Unknown,
	Asking,
	Signed_In,
	Signed_Out,
}
// One answer per Codex home: slot 0 the default account's (the environment's), the others a
// home's by its folder (set on the main thread only; the worker writes its slot's state).
@(private = "file")
CODEX_LOGIN_SLOTS :: 16
@(private = "file")
codex_login: [CODEX_LOGIN_SLOTS]struct {
	home:  string, // heap; "" = the default (slot 0) or free
	state: Codex_Login, // atomic
	gen:   i32, // atomic
}

CODEX_LOGIN_TIMEOUT :: 15 * time.Second

// The slot of an account's answer (account: a tab's; "" or the default's folder = slot 0); -1 =
// none (more homes than slots: no bar for it). take: take a free slot. Main thread.
@(private = "file")
codex_login_slot :: proc(account: string, take := false) -> int {
	d := claude_account_dir(account, codex = true)
	if account == "" || d == codex_home() do return 0
	for x, i in codex_login do if i > 0 && x.home == d do return i
	if !take do return -1
	for &x, i in codex_login do if i > 0 && x.home == "" {
		x.home = strings.clone(d, runtime.heap_allocator())
		return i
	}
	return -1
}

codex_login_state :: proc(account := "") -> Codex_Login {
	i := codex_login_slot(account)
	return i < 0 ? .Unknown : Codex_Login(sync.atomic_load(&codex_login[i].state))
}

// Sets the answer for account's home (tests; and Unknown once its composer reports).
codex_login_set :: proc(s: Codex_Login, account := "") {
	if i := codex_login_slot(account, take = true); i >= 0 do sync.atomic_store(&codex_login[i].state, s)
}

// Asks once for account's home (a configured one; "" = the default, which sets no CODEX_HOME).
codex_login_check :: proc(account := "") {
	if account != "" && !claude_account_known(account, codex = true) do return
	i := codex_login_slot(account, take = true)
	if i < 0 do return
	if _, ok := sync.atomic_compare_exchange_strong(&codex_login[i].state, .Unknown, .Asking); !ok do return
	gen := sync.atomic_load(&codex_login[i].gen)
	// its home after the login profile, as its tabs (CODEX_ACCOUNT_SH): the marker as a shell
	// variable in the script (a configured folder, quoted), nothing for the default
	set := ""
	for e in claude_account_env(account, codex = true) do if strings.has_prefix(e, "DECKHAND_CODEX_ACCOUNT=") {
		set = strings.concatenate({"DECKHAND_CODEX_ACCOUNT=", sh_quote(e[len("DECKHAND_CODEX_ACCOUNT="):]), "; "}, context.temp_allocator)
	}
	script := strings.clone(strings.concatenate({"set -- login status; ", set, CODEX_ACCOUNT_SH, codex_tab_cmd()}, context.temp_allocator))
	Job :: struct {
		slot:   int,
		gen:    i32,
		script: string,
	}
	thread.create_and_start_with_poly_data(Job{i, gen, script}, proc(j: Job) {
		defer free_all(context.temp_allocator)
		defer delete(j.script)
		_, code, ran := run_bounded_exit("", shell_script_argv(login_shell(), j.script, "codex")[:], CODEX_LOGIN_TIMEOUT)
		ans := Codex_Login.Unknown // a timeout or another failure proves nothing: no bar
		if ran && code == 0 do ans = .Signed_In
		else if ran && code == 1 do ans = .Signed_Out
		x := &codex_login[j.slot]
		if sync.atomic_load(&x.gen) == j.gen do sync.atomic_compare_exchange_strong(&x.state, .Asking, ans)
		if platform.wake != nil do platform.wake()
	}, self_cleanup = true)
}

// ---- the credential guard ----

// Codex's folder: CODEX_HOME as tabs get it when absolute, else ~/.codex. Temp.
codex_home :: proc() -> string {
	home := strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")
	if h, ok := env_lookup(child_base_env(), "CODEX_HOME"); ok && filepath.is_abs(h) {
		h = strings.trim_right(h, "/")
		// never HOME or a folder above it (all of HOME would be "Codex's")
		if h != "" && h != home && !(home != "" && path_under(home, h)) do return h
	}
	if home == "" do return ""
	return strings.concatenate({home, "/.codex"}, context.temp_allocator)
}

// The files in Codex's folder a user edits: everything else there is Codex's state (its sign-in
// auth.json, sessions/ transcripts, history, logs, databases), refused wherever Claude's
// credentials are (settings_credential: open, show, upload, list, watch) and never written. One
// exception, read only: the found-row scan lists sessions/, reads each rollout's first line and
// session_index.jsonl's titles (codex_disk.odin, docs/CODEX.md §2b).
CODEX_CONFIG_FILES := [?]string{"config.toml", "AGENTS.md", "AGENTS.override.md"}
CODEX_CONFIG_FOLDERS := [?]string{"prompts", "skills", "rules"}
// Codex's own hooks (its hooks.json, scripts in hooks/): the user's, shown, never written by
// Deckhand, not even on the user's Save (the editor opens them read-only: codex_view_only).
// plugins/ is not here: Codex fills it itself (installed plugins and their marketplaces).
CODEX_VIEW_FILES := [?]string{"hooks.json"}
CODEX_VIEW_FOLDERS := [?]string{"hooks"}

// Whether p (clean, absolute) is Codex's sign-in or state rather than the user's config.
// Codex's sign-in file as Codex finds it: $CODEX_HOME/auth.json (as tabs get it, absolute; HOME or
// above too), else ~/.codex/auth.json. "" = no HOME. Temp.
codex_auth_file :: proc() -> string {
	if h, ok := env_lookup(child_base_env(), "CODEX_HOME"); ok && filepath.is_abs(h) {
		return strings.concatenate({strings.trim_right(h, "/"), "/auth.json"}, context.temp_allocator)
	}
	home := strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")
	if home == "" do return ""
	return strings.concatenate({home, "/.codex/auth.json"}, context.temp_allocator)
}

codex_credential :: proc(p: string) -> bool {
	if filepath.base(p) == "auth.json" && filepath.base(filepath.dir(p)) == ".codex" do return true
	// the sign-in where Codex keeps it, CODEX_HOME's even when that is HOME or above (codex_home
	// is not then); symlinks followed
	if a := codex_auth_file(); a != "" {
		ra := fs_real(a)
		if p == a || (ra != "" && (p == ra || fs_real(p) == ra)) do return true
	}
	// every Codex home (claude_account_dirs with codex): the default's, ~/.codex, each account's,
	// a removed one's while it holds Codex's files; never HOME or above it. Codex's state if any
	// home says so (one home may sit in another's config folder: ~/a/skills/b)
	for home in claude_account_dirs(codex = true) {
		for c in ([2]string{home, fs_real(home)}) {
			if c == "" || !path_under(p, c) do continue
			first, _, rest := strings.partition(p[len(c) + 1:], "/")
			config := false
			for f in CODEX_CONFIG_FOLDERS do if first == f do config = true
			if rest == "" do for f in CODEX_CONFIG_FILES do if first == f do config = true
			for f in CODEX_VIEW_FOLDERS do if first == f do config = true
			if rest == "" do for f in CODEX_VIEW_FILES do if first == f do config = true
			if !config do return true
		}
	}
	return false
}

// Codex's sign-in files, every home's (their other names, hard links, are refused too:
// credential_ids).
codex_credential_files :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for h in claude_account_dirs(codex = true) do append(&out, strings.concatenate({h, "/auth.json"}, context.temp_allocator))
	if a := codex_auth_file(); a != "" && !slice_has(out[:], a) do append(&out, a)
	return out[:]
}

@(private = "file")
slice_has :: proc(list: []string, x: string) -> bool {
	for y in list do if y == x do return true
	return false
}

// Whether p is strictly inside folder dir (by name).
@(private = "file")
path_under :: proc(p, dir: string) -> bool {return dir != "" && len(p) > len(dir) && strings.has_prefix(p, dir) && p[len(dir)] == '/'}

// codex_missing for a Codex start, else claude_missing.
claude_harness_missing :: proc(codex: bool, caller: Caller) -> (r: Result, missing: bool) {
	if codex do return codex_missing(caller)
	return claude_missing(caller)
}


// Why text Deckhand puts into a Codex tab's composer on its own initiative (a dropped file's path,
// anyone's send_text but the user's own) cannot go now ("" = it can; not a Codex tab: ""): the
// composer rule (codex_command_text), and Codex not working or blocked (Enter or a paste mid-turn
// would steer it; a dialog would take it). The user typing beside it is fine: it is added to
// their text, never sent. Held prompts have their own, stricter path (Claude_Deliver).
codex_paste_refusal :: proc(tab: ^Tab, text: string) -> string {
	ct, is := &tab.kind.(Claude_Tab)
	if !is || !ct.codex do return ""
	if !replica_process && codex_plain_version(tab.id) != "" do return CODEX_PLAIN_REFUSAL // nothing typed into a plain tab
	if why := codex_command_text(text); why != "" do return why
	w := replica_process ? tab.live.claude_wait : claude_wait_of(tab, ct) // a window's replica: the core's (Tab_Live)
	if tab.status != .Running do w = .Not_Running
	if w == .Typing do w = .None
	return CODEX_WAIT_WHY[w]
}

// ---- one id, one harness ----

// Whether id is a Claude Code conversation Deckhand can see: its history's, the disk index's, or a
// transcript of p's (by stat, claude_disk_find; no scan). A Codex tab never claims one.
claude_conversation_seen :: proc(p: ^Project, id: string) -> bool {
	if r, _ := claude_record(id); r != nil && !r.codex do return true
	if f := claude_disk_of(id); f != nil && f.harness != .Codex do return true
	_, ok := claude_disk_find(p, id)
	return ok
}
