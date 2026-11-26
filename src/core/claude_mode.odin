package core

// A Claude or Codex tab's permission mode, for the quiet badge on its tab and its tooltip
// (docs/CLAUDE-TABS.md §4b, docs/CODEX.md §1a). Never guessed, and never safer-sounding than it may be:
//   - Claude Code: what its hooks report comes first (`permission_mode` on claude.session and
//     claude.turn: SessionStart, UserPromptSubmit, Stop, Notification), so Shift+Tab's switches
//     show at the next prompt or turn's end; "default" clears it. Until one does: the flags the tab
//     started with (claude_start: its own and, for a start the user makes, the user's defaults as
//     they went): --permission-mode, --dangerously-skip-permissions. A tab started with
//     skip-permissions keeps its bypass badge until its process starts again, whatever a report
//     says: any process in the tab holds its token, so a report could lower it (the badge is
//     information, not a security boundary).
//   - Codex: its start flags only (Codex reports no mode, Deckhand reads no config.toml or
//     profile), parsed as codex_args_choose_access decides on full access (codex_access_choices):
//     --dangerously-bypass-approvals-and-sandbox, a sandbox of danger-full-access (-s or -c
//     sandbox_mode), approvals never (-a or -c approval_policy), --approve-for-me. Only those: no
//     badge for a safer-sounding one (read-only), since a mode changed inside Codex or set in its
//     config is not seen: a Codex tab with no badge is not known to be in the default mode.
// Kept as the harness's own word (Claude_Tab.permission_mode, on the state stream; "" = the
// default or not known); claude_mode_label is what the tab shows: anything that is not known to
// ask before it acts (auto, bypass, an unknown word) is in the warning colour.

import "core:strings"

CLAUDE_MODE_MAX :: 32 // a reported mode's length, at most (letters only)

// Codex's modes from its flags (Codex reports none): Deckhand's own words, never Codex's.
CODEX_MODE_BYPASS :: "codex-bypass"
CODEX_MODE_FULL_ACCESS :: "codex-full-access"
CODEX_MODE_NEVER_ASKS :: "codex-never-asks"
CODEX_MODE_APPROVES :: "codex-approves"

// A mode as one word: ASCII letters, 1..CLAUDE_MODE_MAX ("" = not one).
claude_mode_word :: proc(m: string) -> string {
	if len(m) == 0 || len(m) > CLAUDE_MODE_MAX do return ""
	for ch in transmute([]u8)m do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z') do return ""
	return m
}

// What the tab shows for mode ("" = nothing: the default, or none), and whether it is the
// warning's: anything but a mode known to ask first (plan, accept edits, don't ask).
claude_mode_label :: proc(mode: string) -> (label: string, warn: bool) {
	switch mode {
	case "", "default":          return "", false
	case "plan":                 return "plan", false
	case "acceptEdits":          return "accept edits", false
	case "dontAsk":              return "don't ask", false
	case "auto":                 return "auto", true
	case "bypassPermissions":    return "bypass", true
	case CODEX_MODE_BYPASS:      return "bypass", true
	case CODEX_MODE_FULL_ACCESS: return "full access", true
	case CODEX_MODE_NEVER_ASKS:  return "never asks", true
	case CODEX_MODE_APPROVES:    return "approves for you", true
	}
	// a mode a newer Claude Code reports: its own word, as it said it, and unknown: the warning's
	w := claude_mode_word(mode)
	return w, w != ""
}

// One of a Codex tab's flags that chooses how Codex asks or sandboxes (codex_access_choices).
Codex_Access :: struct {
	what:  string, // "sandbox", "approval", "approve-for-me", "bypass", or a -c key: "sandbox_mode", "approval_policy", "sandbox_workspace_write"
	value: string, // its value, `=` and quotes off ("" for a flag with none)
}

// Every flag of args (passed codex_args_check) that chooses how Codex asks or sandboxes, in order:
// -s/--sandbox, -a/--ask-for-approval, --approve-for-me, full access itself, a -c of
// approval_policy, sandbox_mode or sandbox_workspace_write; every spelling codex_args_check takes
// (`-s v`, `-sv`, `-s=v`, `--sandbox v`, `--sandbox=v`). codex_args_choose_access (full access's
// rule) and the badge both read this, so they cannot disagree. Temp.
codex_access_choices :: proc(args: []string) -> []Codex_Access {
	out := make([dynamic]Codex_Access, context.temp_allocator)
	unquote :: proc(s: string) -> string {return strings.trim(strings.trim_space(s), `"'`)}
	next :: proc(args: []string, i: int) -> string {return i + 1 < len(args) ? args[i + 1] : ""}
	for a, i in args {
		if len(a) < 2 || a[0] != '-' do continue
		kv := ""
		if a[1] == '-' {
			n, eq, v := strings.partition(a, "=")
			val := eq != "" ? v : next(args, i)
			switch n {
			case "--sandbox":                                  append(&out, Codex_Access{"sandbox", unquote(val)})
			case "--ask-for-approval":                         append(&out, Codex_Access{"approval", unquote(val)})
			case "--approve-for-me":                           append(&out, Codex_Access{"approve-for-me", ""})
			case "--dangerously-bypass-approvals-and-sandbox": append(&out, Codex_Access{"bypass", ""})
			case "--config":                                   kv = val
			}
		} else {
			val := len(a) > 2 ? strings.trim_prefix(a[2:], "=") : next(args, i)
			switch a[1] {
			case 's': append(&out, Codex_Access{"sandbox", unquote(val)})
			case 'a': append(&out, Codex_Access{"approval", unquote(val)})
			case 'c': kv = val
			}
		}
		if kv == "" do continue
		key, _, value := strings.partition(kv, "=")
		first, _, _ := strings.partition(strings.trim_space(key), ".")
		switch k := unquote(first); k {
		case "approval_policy", "sandbox_mode", "sandbox_workspace_write": append(&out, Codex_Access{k, unquote(value)})
		}
	}
	return out[:]
}

// The mode a tab's start flags set ("" = none stated, or none worth a badge). args: as they went
// (the defaults in).
claude_mode_of_args :: proc(h: Harness, args: []string) -> string {
	if harness_is_codex(h) {
		// the strongest, whatever the order: bypass, full access, never asks, approves for you
		rank := 0
		for c in codex_access_choices(args) {
			r := 0
			switch c.what {
			case "bypass":                          r = 4
			case "sandbox", "sandbox_mode":         if c.value == "danger-full-access" do r = 3
			case "approval", "approval_policy":     if c.value == "never" do r = 2
			case "approve-for-me":                  r = 1
			}
			rank = max(rank, r)
		}
		switch rank {
		case 4: return CODEX_MODE_BYPASS
		case 3: return CODEX_MODE_FULL_ACCESS
		case 2: return CODEX_MODE_NEVER_ASKS
		case 1: return CODEX_MODE_APPROVES
		}
		return ""
	}
	mode := ""
	for a, i in args {
		if a == "--dangerously-skip-permissions" do return "bypassPermissions"
		v := ""
		if a == "--permission-mode" do v = i + 1 < len(args) ? args[i + 1] : ""
		else if strings.has_prefix(a, "--permission-mode=") do v = a[len("--permission-mode="):]
		else do continue
		if w := claude_mode_word(v); w != "" do mode = w
	}
	return mode == "default" ? "" : mode
}

// Tabs whose process started with skip-permissions (their flags said bypass): their badge is not
// lowered by a report until the process starts again (claude_start). Heap, by tab id.
@(private = "file")
mode_floor: map[u64]bool

// Sets ct's mode (a word, or ""); true if it changed.
claude_mode_set :: proc(ct: ^Claude_Tab, mode: string) -> bool {
	if ct.permission_mode == mode do return false
	delete(ct.permission_mode)
	ct.permission_mode = mode != "" ? strings.clone(mode) : ""
	return true
}

// claude_start: the mode the start's flags set, and whether its badge may be lowered by reports.
claude_mode_started :: proc(tab_id: u64, ct: ^Claude_Tab, args: []string) {
	m := claude_mode_of_args(ct.harness, args)
	claude_mode_set(ct, m)
	if m == "bypassPermissions" do mode_floor[tab_id] = true
	else do delete_key(&mode_floor, tab_id)
}

// The tab is gone (tab_free_kind).
claude_mode_forget :: proc(tab_id: u64) {delete_key(&mode_floor, tab_id)}

// A hook's report of Claude Code's mode (claude.session, claude.turn): "" = not said (an older
// plugin, an event without it), kept as it was; "default" clears it, unless the process started
// with skip-permissions (mode_floor). A Codex tab's reports are not looked at (Codex's hooks carry
// none). True if it changed.
claude_mode_report :: proc(tab_id: u64, ct: ^Claude_Tab, reported: string) -> bool {
	if harness_is_codex(ct.harness) do return false
	w := claude_mode_word(reported)
	if w == "" do return false
	if tab_id in mode_floor {
		if _, warn := claude_mode_label(w); !warn do return false // never lowered below bypass
	}
	return claude_mode_set(ct, w == "default" ? "" : w)
}

// The tooltip's words for ct's mode ("" = none): "plan mode", "bypass mode".
claude_mode_tip :: proc(ct: Claude_Tab) -> string {
	label, _ := claude_mode_label(ct.permission_mode)
	if label == "" do return ""
	return strings.concatenate({label, " mode"}, context.temp_allocator)
}
