package core

// The user's flags for harness tabs (docs/GUIDE.md "Flags for a tab"; docs/CLAUDE.md §1,
// docs/CODEX.md §3):
//
//   - Per tab: new_claude_tab / new_claude_session / new_chat take `args` from the user (and
//     scripts) only, checked by the harness's own rule: Claude Code's refusals (claude_args_check),
//     Codex's allowlist (codex_args_check), pi's allowlist here (pi_args_check). The window's
//     "… with flags…" entries type them as one line, split here as a shell splits words
//     (flags_split: quotes honoured, nothing evaluated).
//   - Defaults: one line per harness in Settings › Coding agents (Set_Harness_Flags, this Mac's
//     user's only: User_Here, like the skip-permissions switch), checked by the same rule when set
//     and again when used. At each start the user makes they go first and the tab's own flags
//     after them (harness_with_defaults; a default the tab names itself is left out), as the
//     setting is NOW: never saved into a tab's or a record's flags. Claude Code and Codex: the
//     starts claude_start makes with `defaults` (the user's new tab, session, chat, resume, restore
//     and restart). pi: the user's new session (new_chat, worktree_session); pi keeps a session's
//     model itself when it resumes. Agents', scripts' and panels' starts never get them.

import "core:fmt"
import "core:strings"

// Settings › Coding agents › <harness> › Default flags (this Mac's user's only).
Set_Harness_Flags :: struct {
	harness: Harness,
	flags:   string, // one line, split as a shell splits words (flags_split); "" = none
}

FLAGS_TEXT_MAX :: 4096

// One line into words as a POSIX shell splits them, without evaluating anything: blanks separate
// words; '…' is literal; in "…" a backslash escapes only $ ` " and \; outside quotes a backslash
// escapes the next character. $, `, globs, ~ and ; are plain characters. err: an open quote or a
// trailing backslash. ''/"" make an empty word (the harness's rule refuses it).
flags_split :: proc(line: string, allocator := context.temp_allocator) -> (args: []string, err: string) {
	out := make([dynamic]string, allocator)
	word := strings.builder_make(context.temp_allocator)
	in_word := false
	quote: u8 = 0
	for i := 0; i < len(line); i += 1 {
		ch := line[i]
		switch quote {
		case '\'':
			if ch == '\'' do quote = 0
			else do strings.write_byte(&word, ch)
			continue
		case '"':
			if ch == '"' {
				quote = 0
			} else if ch == '\\' && i + 1 < len(line) && strings.index_byte("$`\"\\", line[i + 1]) >= 0 {
				i += 1
				strings.write_byte(&word, line[i])
			} else do strings.write_byte(&word, ch)
			continue
		}
		switch ch {
		case ' ', '\t':
			if in_word {
				append(&out, strings.clone(strings.to_string(word), allocator))
				strings.builder_reset(&word)
				in_word = false
			}
		case '\'', '"':
			quote = ch
			in_word = true
		case '\\':
			if i + 1 >= len(line) do return nil, "a backslash at the end of the flags"
			i += 1
			strings.write_byte(&word, line[i])
			in_word = true
		case:
			strings.write_byte(&word, ch)
			in_word = true
		}
	}
	if quote != 0 do return nil, fmt.tprintf("a %c quote is not closed", quote)
	if in_word do append(&out, strings.clone(strings.to_string(word), allocator))
	return out[:], ""
}

// args as one line flags_split reads back the same: a word with anything but letters, digits and
// -_=.,:/+@% in single quotes (a ' as '\''). Temp.
flags_join :: proc(args: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for a, i in args {
		if i > 0 do strings.write_byte(&b, ' ')
		plain := a != ""
		for ch in transmute([]u8)a do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || strings.index_byte("-_=.,:/+@%", ch) >= 0) {
			plain = false
			break
		}
		if plain {
			strings.write_string(&b, a)
			continue
		}
		strings.write_byte(&b, '\'')
		for ch in transmute([]u8)a {
			if ch == '\'' do strings.write_string(&b, `'\''`)
			else do strings.write_byte(&b, ch)
		}
		strings.write_byte(&b, '\'')
	}
	return strings.to_string(b)
}

// Why these flags cannot go to a harness's tab ("" = they can): its own rule.
harness_args_check :: proc(h: Harness, args: []string) -> string {
	switch h {
	case .Claude: return claude_args_check(args)
	case .Codex:  return codex_args_check(args)
	case .Pi:     return pi_args_check(args)
	}
	return ""
}

// ---- pi ----

// The pi flags a tab may take (pi 1.5's `pi --help`, docs/cli.md): the model, its provider and
// thinking, the model scope, and switches that change nothing Deckhand relies on. pi reads a
// value as the next word only (`--model x`; `--model=x` would be an extension's flag).
@(private = "file")
PI_FLAGS_OK := [?]struct {
	name:  string,
	value: bool,
} {
	{"--provider", true},
	{"--model", true},
	{"--thinking", true},
	{"--models", true},
	{"--tui-mode", true},
	{"--use-theme", true},
	{"--offline", false},
	{"--verbose", false},
	{"--no-mcp", false},
}

PI_NOT_A_FLAG :: "an argument that is not a flag: pi would take it for a prompt"
PI_SESSION_WHY :: "Deckhand picks the session"
PI_MODE_WHY :: "a pi tab runs pi's terminal UI"
PI_EXT_WHY :: "Deckhand's pi integration loads as extensions"

// pi flags refused by name, and why (the others not in PI_FLAGS_OK: "not one Deckhand passes").
@(private = "file")
PI_FLAGS_REFUSED := [?][2]string {
	{"-e", PI_EXT_WHY},
	{"--extension", PI_EXT_WHY},
	{"-ne", PI_EXT_WHY},
	{"--no-extensions", PI_EXT_WHY},
	{"--session", PI_SESSION_WHY},
	{"--session-id", PI_SESSION_WHY},
	{"--session-dir", PI_SESSION_WHY},
	{"--fork", PI_SESSION_WHY},
	{"--no-session", PI_SESSION_WHY},
	{"-c", PI_SESSION_WHY},
	{"--continue", PI_SESSION_WHY},
	{"-r", PI_SESSION_WHY},
	{"--resume", PI_SESSION_WHY},
	{"-p", PI_MODE_WHY},
	{"--print", PI_MODE_WHY},
	{"--mode", PI_MODE_WHY},
	{"--export", "it writes a file and exits"},
	{"--list-models", "it prints and exits"},
	{"-h", "it prints and exits"},
	{"--help", "it prints and exits"},
	{"-v", "it prints and exits"},
	{"--version", "it prints and exits"},
	{"--api-key", "a key on the command line shows in ps: use pi's /login or its environment variable"},
	{"-nt", "it turns off the tools Deckhand's integration adds"},
	{"--no-tools", "it turns off the tools Deckhand's integration adds"},
}

// Why these flags cannot go to a pi tab ("" = they can): at most CLAUDE_ARGS_MAX; no empty, long or
// multi-line one; flags only (another word would be a prompt or an @file); only PI_FLAGS_OK, a
// value-taking one with its value as the next word (never one starting with "-").
pi_args_check :: proc(args: []string) -> string {
	if len(args) > CLAUDE_ARGS_MAX do return fmt.tprintf("at most %d extra flags", CLAUDE_ARGS_MAX)
	for a in args do if a == "" || len(a) > 1024 || strings.contains_any(a, "\x00\r\n") do return "an extra flag is empty, too long or has a line break"
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if len(a) < 2 || a[0] != '-' || a == "--" do return PI_NOT_A_FLAG
		name, eq, _ := strings.partition(a, "=")
		for r in PI_FLAGS_REFUSED do if name == r[0] do return fmt.tprintf("%s is refused: %s", r[0], r[1])
		found := false
		value := false
		for f in PI_FLAGS_OK do if a == f.name {
			found, value = true, f.value
			break
		}
		if !found {
			if eq != "" do for f in PI_FLAGS_OK do if name == f.name do return fmt.tprintf("pi takes %s and its value as two words: %s <value>", f.name, f.name)
			return fmt.tprintf("%s is not a pi flag Deckhand passes on", flag_shown(a))
		}
		if !value do continue
		if i + 1 >= len(args) || strings.has_prefix(args[i + 1], "-") do return fmt.tprintf("%s needs a value", a)
		i += 1
	}
	return ""
}

// ---- defaults ----

// The user's default flags for h (Settings), split; none when they no longer pass its rule (a file
// from an older Deckhand). Temp.
harness_default_args :: proc(h: Harness) -> []string {
	text := strings.trim_space(state.settings.harness_flags[h])
	if text == "" do return nil
	args, err := flags_split(text)
	if err != "" || harness_args_check(h, args) != "" do return nil
	return args
}

// The name a flag goes by, to tell whether a tab's own flags name a default (temp): before an
// `=`; Codex's short ones by their long name and its -c by its key ("--config:<key>"). "" = not a
// flag (a prompt word of Claude Code's).
@(private = "file")
flag_key :: proc(h: Harness, a, next: string) -> string {
	if len(a) < 2 || a[0] != '-' do return ""
	name, _, val := strings.partition(a, "=")
	has_val := strings.contains(a, "=")
	if h == .Codex && a[1] != '-' {
		name = a[:2]
		val, has_val = strings.trim_prefix(a[2:], "="), len(a) > 2
	}
	if h == .Codex do name = codex_flag_long(name)
	if h == .Codex && name == "--config" {
		kv := has_val ? val : next
		key, _, _ := strings.partition(kv, "=")
		return strings.concatenate({"--config:", strings.trim_space(key)}, context.temp_allocator)
	}
	return name
}

// args with the user's defaults for h as the setting is NOW before them (temp): a default whose
// flag args name too is left out (with the words after it, up to the next flag); all of them past
// CLAUDE_ARGS_MAX or when the whole does not pass h's rule. Never saved: the callers pass this to
// the start only.
harness_with_defaults :: proc(h: Harness, args: []string) -> []string {
	defaults := harness_default_args(h)
	if len(defaults) == 0 do return args
	named := make(map[string]bool, context.temp_allocator)
	for a, i in args do if k := flag_key(h, a, i + 1 < len(args) ? args[i + 1] : ""); k != "" do named[k] = true
	out := make([dynamic]string, 0, len(defaults) + len(args), context.temp_allocator)
	for i := 0; i < len(defaults); {
		j := i + 1
		for j < len(defaults) && !strings.has_prefix(defaults[j], "-") do j += 1
		k := flag_key(h, defaults[i], i + 1 < len(defaults) ? defaults[i + 1] : "")
		if k == "" || !named[k] do append(&out, ..defaults[i:j])
		i = j
	}
	append(&out, ..args)
	if len(out) > CLAUDE_ARGS_MAX || harness_args_check(h, out[:]) != "" do return args
	return out[:]
}

// Set_Harness_Flags (commands.odin's switch): the harness's own rule, its reason as it is.
harness_flags_apply :: proc(c: Set_Harness_Flags) -> (Result, bool) {
	text := strings.trim_space(c.flags)
	if len(text) > FLAGS_TEXT_MAX do return fail(fmt.tprintf("at most %d characters of flags", FLAGS_TEXT_MAX)), false
	if strings.contains_any(text, "\x00\r\n") do return fail("flags are one line"), false
	args, err := flags_split(text)
	if err != "" do return fail(err), false
	if e := harness_args_check(c.harness, args); e != "" do return fail(e), false
	if text == state.settings.harness_flags[c.harness] do return {ok = true}, false
	delete(state.settings.harness_flags[c.harness])
	state.settings.harness_flags[c.harness] = strings.clone(text)
	settings_gen += 1 // the Settings page's row
	return {ok = true}, true
}

// A flag as a refusal may name it (temp): its text before `=` when that looks like a flag (`-` or
// `--` then letters, digits and `-`, at most 40 characters), else "that flag". Never a value or
// a word that is not a flag: refusals reach the log and agents' events.
flag_shown :: proc(a: string) -> string {
	name, _, _ := strings.partition(a, "=")
	body := strings.trim_prefix(strings.trim_prefix(name, "-"), "-")
	if !strings.has_prefix(name, "-") || body == "" || len(name) > 40 do return "that flag"
	for ch in transmute([]u8)body do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-') do return "that flag"
	return name
}
