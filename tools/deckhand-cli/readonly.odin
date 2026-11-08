package deckhand_cli

// `deckhand hook readonly`: the PreToolUse guard of a read-only Claude tab (a chat while chats are
// read-only; docs/CLAUDE.md §1a). Deckhand puts it in the tab's own `--settings` (an absolute path
// to this binary, matcher "*"), so it runs only in read-only tabs and needs nothing from the
// environment. It is one layer of several: plan mode and Claude Code's own deny rules for the
// tools that write come first; this catches what they let through:
//   - Bash commands pi-kit's read-only guardrails block (MUTATING, ported below; the shared
//     vectors in tests/readonly-vectors.json keep the two the same), background Bash, and
//     `deckhand` act verbs (Deckhand refuses those from a read-only tab anyway);
//   - any tool not on READONLY_TOOLS (a tool a newer Claude Code adds is denied until listed).
// A denial exits 2 with the reason on stderr (Claude Code blocks the call on exit 2, whatever
// else it reads) and the same reason as PreToolUse JSON on stdout. Anything it cannot read is
// denied: a failing guard must never let a call through (the hook's command line adds
// `|| exit 2` for a guard that crashes or is missing).

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// Tools a read-only tab may use without the Bash check: reading, searching, the web, its own
// todo list and questions to the user. Bash is checked (readonly_bash_why); everything else
// (Edit, Write, NotebookEdit, MultiEdit, Agent/Task, Workflow, Cron*, RemoteTrigger, worktrees,
// PowerShell, Monitor, MCP tools, unknown tools) is denied.
READONLY_TOOLS := [?]string {
	"Read", "Glob", "Grep", "LS", "WebFetch", "WebSearch", "TodoWrite", "TodoRead",
	"TaskCreate", "TaskGet", "TaskList", "TaskUpdate", "AskUserQuestion", "EnterPlanMode",
	"ToolSearch", "LSP", "NotebookRead", "Skill",
}

READONLY_DENY_PREFIX :: "Read-only chat (Deckhand): "

// Why a read-only tab may not make this tool call ("" = it may). input: PreToolUse's JSON.
readonly_why :: proc(input: json.Object) -> string {
	if input == nil do return "the tool call could not be read"
	tool, ok := get_str(input, "tool_name")
	if !ok || tool == "" do return "the tool call could not be read"
	if tool == "Bash" {
		ti := get_obj(input, "tool_input")
		cmd, has := get_str(ti, "command")
		if !has do return "the command could not be read"
		if bg, _ := get_bool(ti, "run_in_background"); bg do return "background commands are not allowed"
		return readonly_bash_why(cmd)
	}
	for t in READONLY_TOOLS do if tool == t do return ""
	return fmt.aprintf("%s is not allowed (only reading, searching and the web)", tool)
}

// Why a read-only tab may not run this shell command ("" = it may).
readonly_bash_why :: proc(cmd: string) -> string {
	if mutating(cmd) do return "mutating commands are not allowed"
	if desk_act(cmd) do return "Deckhand's browser and app actions (click, type, press, select, upload, app call, input, open, close, restart) are not allowed"
	return ""
}

// The hook: reads PreToolUse's JSON; a denial prints it and returns 2.
hook_readonly :: proc(c: ^Ctx) -> int {
	raw := c.read_stdin != nil ? c.read_stdin() : ""
	input, _ := parse_obj(raw)
	why := readonly_why(input)
	if why == "" do return 0
	reason := strings.concatenate({READONLY_DENY_PREFIX, why})
	c.write_out(c, fmt.aprintf(`{{"hookSpecificOutput":{{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}}}`, quoted(reason)))
	c.write_out(c, "\n")
	c.write_err(c, strings.concatenate({reason, "\n"}))
	return 2
}

// `deckhand hook readonly-ack NONCE`: the read-only profile's SessionStart hook (Deckhand's
// --settings, nowhere else). Tells Deckhand the profile loaded with this start's nonce; Deckhand
// stops a read-only tab that never says so (docs/CLAUDE.md §1a). Prints nothing (SessionStart
// output goes into Claude's context) and never fails Claude.
hook_readonly_ack :: proc(c: ^Ctx, nonce: string) {
	if c.read_stdin != nil do c.read_stdin()
	if nonce == "" || len(nonce) > 128 do return
	t, terr := transport(c, 3000)
	if terr != "" do return
	r, err := t.call(t, fmt.aprintf(`{{"type":"claude.readonly_ack","nonce":%s}}`, quoted(nonce)), 5000)
	if err != "" || !is_true(r, "ok") do c.write_err(c, "deckhand hook readonly-ack: Deckhand did not take it\n")
}

// ---- pi-kit's MUTATING (extensions/guardrails/core.ts), by hand: Odin's regex has no lookahead.
// Same semantics as the JavaScript regexes (ASCII \b, JavaScript's \s); keep the two in step with
// tests/readonly-vectors.json. ----

// Whether a read-only session blocks this command: pi-kit's MUTATING (any regex matches), and
// Deckhand's own additions (m_deckhand; not in pi-kit yet: tests/readonly-vectors.json deny_deckhand).
mutating :: proc(cmd: string) -> bool {
	return m_git(cmd, GIT_VERBS[:], true) || m_fs(cmd) || m_redirect(cmd) || m_sed_i(cmd) || m_deckhand(cmd)
}

@(private = "file")
GIT_VERBS := [?]string{"commit", "push", "merge", "rebase", "reset", "checkout", "switch", "stash", "apply", "am", "cherry-pick", "revert", "tag"}
@(private = "file")
GIT_VERBS_DECKHAND := [?]string{"clean", "restore", "pull", "add", "init", "config", "update-ref"}

@(private = "file")
is_word :: proc(ch: u8) -> bool {
	return ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_'
}

// \b at byte i (between s[i-1] and s[i]); multi-byte characters are never word characters,
// as in a JavaScript regex without the u flag.
@(private = "file")
boundary :: proc(s: string, i: int) -> bool {
	before := i > 0 && is_word(s[i - 1])
	after := i < len(s) && is_word(s[i])
	return before != after
}

// JavaScript's \s at byte i: its length in bytes (0 = not a space).
@(private = "file")
js_space :: proc(s: string, i: int) -> int {
	if i >= len(s) do return 0
	switch s[i] {
	case ' ', '\t', '\n', '\v', '\f', '\r': return 1
	}
	if s[i] < 0x80 do return 0
	r, n := utf8.decode_rune_in_string(s[i:])
	switch r {
	case 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return n
	case 0x2000 ..= 0x200A: return n
	}
	return 0
}

// \s+ at i: the bytes it takes (0 = none).
@(private = "file")
spaces :: proc(s: string, i: int) -> int {
	j := i
	for {
		n := js_space(s, j)
		if n == 0 do break
		j += n
	}
	return j - i
}

// A word at i: s[i:] starts with w and \b follows it.
@(private = "file")
word_at :: proc(s: string, i: int, w: string) -> bool {
	return strings.has_prefix(s[i:], w) && boundary(s, i + len(w))
}

// /\bgit\b[^|;&]*\b(?:commit|push|merge|rebase|reset|checkout|switch|stash|apply|am|cherry-pick|
// revert|tag|branch\s+-[dDmM]|worktree\s+(?:add|remove))\b/
// (Deckhand's extra git verbs reuse it without the branch and worktree forms.)
@(private = "file")
m_git :: proc(s: string, verbs: []string, forms: bool) -> bool {
	for k := 0; k + 3 <= len(s); k += 1 {
		if !boundary(s, k) || !word_at(s, k, "git") do continue
		for p := k + 3; p <= len(s); p += 1 {
			if p > k + 3 && strings.index_byte("|;&", s[p - 1]) >= 0 do break // [^|;&]* ends before
			if !boundary(s, p) do continue
			for v in verbs do if word_at(s, p, v) do return true
			if !forms do continue
			if strings.has_prefix(s[p:], "branch") {
				q := p + 6
				if n := spaces(s, q); n > 0 && q + n + 1 < len(s) && s[q + n] == '-' && strings.index_byte("dDmM", s[q + n + 1]) >= 0 && boundary(s, q + n + 2) do return true
			}
			if strings.has_prefix(s[p:], "worktree") {
				q := p + 8
				if n := spaces(s, q); n > 0 && (word_at(s, q + n, "add") || word_at(s, q + n, "remove")) do return true
			}
		}
	}
	return false
}

// /\b(?:rm|mv|cp|chmod|chown|touch|mkdir|tee)\b/
@(private = "file")
m_fs :: proc(s: string) -> bool {
	words := [?]string{"rm", "mv", "cp", "chmod", "chown", "touch", "mkdir", "tee"}
	for k := 0; k < len(s); k += 1 {
		if !boundary(s, k) do continue
		for w in words do if word_at(s, k, w) do return true
	}
	return false
}

// /(?:^|[^<>&0-9=-])>{1,2}(?![>&])(?!\s*\/dev\/null)/
@(private = "file")
m_redirect :: proc(s: string) -> bool {
	for i := 0; i < len(s); i += 1 {
		if s[i] != '>' do continue
		if i > 0 {
			p := s[i - 1]
			if strings.index_byte("<>&=-", p) >= 0 || p >= '0' && p <= '9' do continue
		}
		run := 0
		for i + run < len(s) && s[i + run] == '>' do run += 1
		// >{1,2} backtracks from two to one; a third '>' or a following '&' fails both
		for m := min(run, 2); m >= 1; m -= 1 {
			at := i + m
			if at < len(s) && (s[at] == '>' || s[at] == '&') do continue
			if strings.has_prefix(s[at + spaces(s, at):], "/dev/null") do continue
			return true
		}
	}
	return false
}

// /\bsed\s+[^|;&]*-i\b/
@(private = "file")
m_sed_i :: proc(s: string) -> bool {
	for k := 0; k + 3 <= len(s); k += 1 {
		if !boundary(s, k) || !strings.has_prefix(s[k:], "sed") do continue
		n := spaces(s, k + 3)
		if n == 0 do continue
		for j := k + 3 + n; j + 2 <= len(s); j += 1 {
			if s[j] == '|' || s[j] == ';' || s[j] == '&' do break
			if s[j] == '-' && s[j + 1] == 'i' && boundary(s, j + 2) do return true
		}
	}
	return false
}

// ---- Deckhand act verbs ----

// Whether the command runs Deckhand's CLI with a verb that acts on a page or an app (Deckhand
// refuses them from a read-only tab's token too; this says so before the call). A `deckhand`,
// `pi-desk` (its old name, an alias) or `pi-desk-cli` word followed, after options, by an act verb.
// In any case (`Deckhand click`, `PI-DESK click`): macOS file names ignore case, so those run too.
desk_act :: proc(cmd: string) -> bool {
	s := strings.to_lower(cmd, context.temp_allocator)
	acts := [?]string{"click", "type", "press", "select", "upload"}
	for k := 0; k < len(s); k += 1 {
		if k > 0 && (is_word(s[k - 1]) || s[k - 1] == '-') do continue
		j: int
		switch {
		case strings.has_prefix(s[k:], "deckhand"):
			j = k + len("deckhand")
		case strings.has_prefix(s[k:], "pi-desk"):
			j = k + len("pi-desk")
			if strings.has_prefix(s[j:], "-cli") do j += 4
		case:
			continue
		}
		if j < len(s) && (is_word(s[j]) || s[j] == '-') do continue
		// the next words: an act verb, or `app call` / `app input` / `app open|close|restart`
		words := strings.fields(s[j:min(len(s), j + 200)], context.temp_allocator)
		for w, i in words {
			if i > 3 do break
			for a in acts do if w == a do return true
			if w == "app" && i + 1 < len(words) {
				switch words[i + 1] {
				case "call", "input", "open", "close", "restart": return true
				}
			}
		}
	}
	return false
}

// ---- Deckhand's additions (not in pi-kit's MUTATING yet) ----
// These match only where the program is the command word of a segment (or git's subcommand), so
// `cat ln.txt`, `grep -rn unlink src` and `git log -- add.md` run. The command word: the first
// word of a segment (split at | ; & ( ) { } ` and newlines, so `$(…)` and `if …; then …` count),
// after variable assignments, shell keywords and wrappers (sudo, xargs, env, command, nohup,
// timeout, …, with their options), as its basename (/bin/ln is ln), quotes dropped; and the
// first word of the string after a shell's -c.

@(private = "file")
Cmd :: struct {
	name: string, // basename, quotes dropped
	args: []string, // the words after it in its segment, quotes dropped
}

// A word without its quotes and backslashes (temp).
@(private = "file")
unquote :: proc(w: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(w) do if w[i] != '\'' && w[i] != '"' && w[i] != '\\' do strings.write_byte(&b, w[i])
	return strings.to_string(b)
}

@(private = "file")
WRAPPERS := [?]string{"sudo", "doas", "xargs", "env", "command", "builtin", "exec", "nohup", "time", "nice", "ionice", "timeout", "stdbuf", "caffeinate", "chroot", "!", "if", "then", "else", "elif", "do", "while", "until"}
// Whether a wrapper's option takes the next word as its value (each wrapper's own: sudo's -E
// takes none, so `sudo -E ln` is ln). Unknown options take none: the next word is then checked.
@(private = "file")
wrapper_valued :: proc(wrapper, o: string) -> bool {
	vals: []string
	switch wrapper {
	case "sudo":    vals = {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T", "--user", "--group", "--chdir", "--prompt", "--role", "--type", "--host", "--other-user", "--close-from", "--command-timeout"}
	case "doas":    vals = {"-u", "-C"}
	case "xargs":   vals = {"-I", "-L", "-n", "-P", "-s", "-E", "-d", "-a", "--max-args", "--max-procs", "--max-lines", "--max-chars", "--arg-file", "--delimiter", "--eof"}
	case "env":     vals = {"-u", "-C", "--unset", "--chdir"}
	case "timeout": vals = {"-s", "-k", "--signal", "--kill-after"}
	case "nice":    vals = {"-n", "--adjustment"}
	case "ionice":  vals = {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata", "--pid", "--pgid", "--uid"}
	case "stdbuf":  vals = {"-i", "-o", "-e", "--input", "--output", "--error"}
	case "caffeinate": vals = {"-t", "-w"}
	case "time":    vals = {"-f", "-o", "--format", "--output"}
	case "exec":    vals = {"-a"}
	case "chroot":  vals = {"--userspec", "--groups"}
	}
	return has(vals, o)
}
@(private = "file")
SHELLS := [?]string{"sh", "bash", "zsh", "dash", "ksh", "fish", "eval"}

// The commands in s (temp): each segment's command word with its arguments.
@(private = "file")
commands :: proc(s: string) -> []Cmd {
	out := make([dynamic]Cmd, context.temp_allocator)
	start := 0
	for i := 0; i <= len(s); i += 1 {
		if i < len(s) && strings.index_byte("|;&(){}`\n", s[i]) < 0 do continue
		words := strings.fields(s[start:i], context.temp_allocator)
		for &w in words do w = unquote(w)
		cmd_words(words, &out)
		start = i + 1
	}
	return out[:]
}

@(private = "file")
has :: proc(list: []string, w: string) -> bool {
	for x in list do if x == w do return true
	return false
}

@(private = "file")
cmd_words :: proc(words: []string, out: ^[dynamic]Cmd) {
	k := 0
	for k < len(words) {
		w := words[k]
		if w == "" {k += 1;continue}
		if eq := strings.index_byte(w, '='); eq > 0 && w[0] != '-' && !strings.contains(w[:eq], "/") {k += 1;continue} // X=1
		name := w[strings.last_index_byte(w, '/') + 1:]
		if has(WRAPPERS[:], name) {
			// its options (and their values; a timeout's duration, chroot's root) up to the command
			k += 1
			chroot_dir := false
			for k < len(words) {
				o := words[k]
				if o == "--" {k += 1;break}
				if strings.has_prefix(o, "-") {
					k += 1
					if wrapper_valued(name, o) && k < len(words) do k += 1
					continue
				}
				if name == "timeout" && len(o) > 0 && o[0] >= '0' && o[0] <= '9' {k += 1;continue}
				if name == "chroot" && !chroot_dir {chroot_dir = true;k += 1;continue} // its new root
				break
			}
			continue
		}
		args := words[k + 1:]
		append(out, Cmd{name = name, args = args})
		// a shell's -c string (or eval's words): its own command
		if has(SHELLS[:], name) {
			for a, j in args {
				if name == "eval" {cmd_words(args, out);break}
				if strings.has_prefix(a, "-") && !strings.has_prefix(a, "--") && strings.contains_rune(a, 'c') {
					cmd_words(args[j + 1:], out)
					break
				}
			}
		}
		return
	}
}

// A cluster of short options ("-sSLo", not "--x"): its letters ("" = not one).
@(private = "file")
short_opts :: proc(a: string) -> string {
	if len(a) < 2 || a[0] != '-' || a[1] == '-' do return ""
	letters := a[1:]
	if i := strings.index_any(letters, "=:."); i >= 0 do letters = letters[:i]
	return letters
}

// Whether a perl switch cluster holds -i as a switch (not inside -M's module or -e's code):
// -i, -pi, -lpi, -0777i; -MList::Util is not.
@(private = "file")
perl_i :: proc(a: string) -> bool {
	if len(a) < 2 || a[0] != '-' || a[1] == '-' do return false
	for j := 1; j < len(a); j += 1 {
		switch a[j] {
		case 'i': return true
		case 'M', 'm', 'I', 'e', 'E', 'd', 'D', 'C', 'x', 'V', 'F': return false // the rest is its value
		case '0', 'l': // their octal or hex digits
			for j + 1 < len(a) && (a[j + 1] >= '0' && a[j + 1] <= '9' || a[j] == '0' && a[j + 1] == 'x') do j += 1
		}
	}
	return false
}

// git's subcommand after its global options (-C dir, -c k=v, --git-dir x, …): "" = none.
@(private = "file")
git_sub :: proc(args: []string) -> (sub: string, rest: []string) {
	for k := 0; k < len(args); k += 1 {
		a := args[k]
		switch {
		case a == "-C" || a == "-c" || a == "--git-dir" || a == "--work-tree" || a == "--namespace" || a == "--config-env" || a == "--super-prefix" || a == "--exec-path":
			k += 1
		case strings.has_prefix(a, "-"):
		case:
			return a, args[k + 1:]
		}
	}
	return "", nil
}

// git config that only reads: --get, --get-all, --get-regexp, --get-urlmatch, --list/-l, or the
// get/list subcommands; and no write (anything else is a set or unset: blocked).
@(private = "file")
git_config_reads :: proc(args: []string) -> bool {
	reads, writes := false, false
	for a in args {
		switch a {
		case "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool", "--list", "-l":
			reads = true
		case "--add", "--unset", "--unset-all", "--replace-all", "--rename-section", "--remove-section", "--edit", "-e":
			writes = true
		}
	}
	// the new form: git config get|list … (set, unset, rename-section, … write)
	for a in args {
		if strings.has_prefix(a, "-") do continue
		if a == "get" || a == "list" do reads = true
		break
	}
	return reads && !writes
}

// git clean|restore|pull|add|init|config (not reading)|update-ref; rmdir, unlink, ln, truncate,
// wget; dd of=; find -delete; perl -i; curl writing a file (-o, -O, --output, --remote-name, -c,
// --cookie-jar, -D, --dump-header); tar extracting or creating (x, c, r, u, A; --extract, --get,
// --create, --append, --update, --delete, --concatenate). Each as the command word only.
@(private = "file")
m_deckhand :: proc(s: string) -> bool {
	for c in commands(s) {
		switch c.name {
		case "git":
			sub, rest := git_sub(c.args)
			if sub == "config" {
				if !git_config_reads(rest) do return true
			} else if has(GIT_VERBS_DECKHAND[:], sub) do return true
		case "rmdir", "unlink", "ln", "truncate", "wget":
			return true
		case "dd":
			for a in c.args do if strings.has_prefix(a, "of=") do return true
		case "find":
			for a in c.args do if a == "-delete" do return true
		case "perl":
			for a in c.args do if perl_i(a) do return true
		case "curl":
			for a in c.args {
				if strings.contains_any(short_opts(a), "oOcD") do return true
				for l in ([]string{"--output", "--remote-name", "--cookie-jar", "--dump-header"}) do if strings.has_prefix(a, l) do return true
			}
		case "tar":
			for a, i in c.args {
				mode := short_opts(a)
				if mode == "" && i == 0 && !strings.has_prefix(a, "-") do mode = a // old style: tar xzf
				if strings.contains_any(mode, "xcruA") do return true
				for l in ([]string{"--extract", "--get", "--create", "--append", "--update", "--delete", "--concatenate"}) do if strings.has_prefix(a, l) do return true
			}
		}
	}
	return false
}
