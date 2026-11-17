package core

// A Claude or Codex tab's permission mode, for the quiet badge on its tab and its tooltip
// (docs/CLAUDE.md §4b, docs/CODEX.md §1a). Never guessed:
//   - what the harness reported comes first: Claude Code's hooks carry `permission_mode`
//     (claude.session, claude.turn: SessionStart, UserPromptSubmit, Stop, Notification), so
//     Shift+Tab's switches show at the next prompt or turn's end; "default" clears it;
//   - else the flags the tab started with (claude_start: its own and, for a start the user makes,
//     the user's defaults as they went): Claude's --permission-mode, --dangerously-skip-permissions;
//     Codex's --dangerously-bypass-approvals-and-sandbox and -s/--sandbox danger-full-access or
//     read-only. Codex's hooks say nothing of it, nor does Deckhand read config.toml or a profile:
//     a Codex tab whose mode comes from them shows no badge.
// Kept as the harness's own word (Claude_Tab.permission_mode, on the state stream; "" = the
// default or not known); claude_mode_label is what the tab shows.

import "core:strings"

CLAUDE_MODE_MAX :: 32 // a reported mode's length, at most (letters only)

// Codex's modes from its flags (Codex reports none): Deckhand's own words, never Codex's.
CODEX_MODE_BYPASS :: "codex-bypass"
CODEX_MODE_FULL_ACCESS :: "codex-full-access"
CODEX_MODE_READ_ONLY :: "codex-read-only"

// A mode as one word: ASCII letters, 1..CLAUDE_MODE_MAX ("" = not one).
claude_mode_word :: proc(m: string) -> string {
	if len(m) == 0 || len(m) > CLAUDE_MODE_MAX do return ""
	for ch in transmute([]u8)m do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z') do return ""
	return m
}

// What the tab shows for mode ("" = nothing: the default, or none), and whether it is the
// warning's: Claude acts, or Codex runs, without asking.
claude_mode_label :: proc(mode: string) -> (label: string, warn: bool) {
	switch mode {
	case "", "default":            return "", false
	case "plan":                   return "plan", false
	case "acceptEdits":            return "accept edits", false
	case "bypassPermissions":      return "bypass", true
	case "dontAsk":                return "don't ask", false
	case "auto":                   return "auto", false
	case CODEX_MODE_BYPASS:        return "bypass", true
	case CODEX_MODE_FULL_ACCESS:   return "full access", true
	case CODEX_MODE_READ_ONLY:     return "read-only", false
	}
	// a mode a newer Claude Code reports: its own word, as it said it
	return claude_mode_word(mode), false
}

// The mode a tab's start flags set ("" = none stated). args: as they went (the defaults in).
claude_mode_of_args :: proc(h: Harness, args: []string) -> string {
	// a flag's value: "--name=v", or the next word ("-sv" too for a one-letter flag)
	value :: proc(args: []string, i: int, long, short: string) -> (v: string, ok: bool) {
		a := args[i]
		if a == long || (short != "" && a == short) do return i + 1 < len(args) ? args[i + 1] : "", true
		if strings.has_prefix(a, long) && len(a) > len(long) && a[len(long)] == '=' do return a[len(long) + 1:], true
		if short != "" && strings.has_prefix(a, short) && len(a) > len(short) && !strings.has_prefix(a, "--") do return a[len(short):], true
		return "", false
	}
	mode := ""
	switch h {
	case .Claude:
		for _, i in args {
			if args[i] == "--dangerously-skip-permissions" do return "bypassPermissions"
			if v, ok := value(args, i, "--permission-mode", ""); ok do if w := claude_mode_word(v); w != "" do mode = w
		}
		if mode == "default" do mode = ""
	case .Codex:
		for _, i in args {
			if args[i] == "--dangerously-bypass-approvals-and-sandbox" do return CODEX_MODE_BYPASS
			if v, ok := value(args, i, "--sandbox", "-s"); ok {
				switch v {
				case "danger-full-access": mode = CODEX_MODE_FULL_ACCESS
				case "read-only":          mode = CODEX_MODE_READ_ONLY
				case:                      mode = ""
				}
			}
		}
	case .Pi:
	}
	return mode
}

// Sets ct's mode (a word, or ""); true if it changed.
claude_mode_set :: proc(ct: ^Claude_Tab, mode: string) -> bool {
	if ct.permission_mode == mode do return false
	delete(ct.permission_mode)
	ct.permission_mode = mode != "" ? strings.clone(mode) : ""
	return true
}

// A hook's report of Claude Code's mode (claude.session, claude.turn): "" = not said (an older
// plugin, an event without it), kept as it was; "default" clears it. A Codex tab's reports are
// not looked at (Codex's hooks carry none). True if it changed.
claude_mode_report :: proc(ct: ^Claude_Tab, reported: string) -> bool {
	if ct.harness == .Codex do return false
	w := claude_mode_word(reported)
	if w == "" do return false
	return claude_mode_set(ct, w == "default" ? "" : w)
}

// The tooltip's words for ct's mode ("" = none): "plan mode", "bypass mode".
claude_mode_tip :: proc(ct: Claude_Tab) -> string {
	label, _ := claude_mode_label(ct.permission_mode)
	if label == "" do return ""
	return strings.concatenate({label, " mode"}, context.temp_allocator)
}
