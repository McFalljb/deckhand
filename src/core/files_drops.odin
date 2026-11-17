package core

// Drops across the Files tree's edges (the native window: ui_files_drops.odin).
//
// A tree drag released over a pane acts on that pane only, by what it shows (pane_drop_action):
// a terminal gets the paths pasted shell-quoted; a pi, Claude Code or Codex tab gets them typed
// into its prompt, never sent (the same paste: their composers take it as text); an editor,
// Markdown, browser, Changes or app tab, or an empty pane, opens the files there as tabs. A
// tab whose program is not running takes nothing.
//
// Files dropped from Finder onto the tree are copied into the folder under the drop
// (files_finder_drop_dir), each with fs_copy (unique names: "name copy").

import "core:path/filepath"
import "core:strings"

Pane_Drop :: enum u8 {
	None,
	Paste_Path, // a terminal: the shell-quoted paths
	Insert_Prompt, // an agent's prompt: the paths as text, never sent
	Open_Here, // the files open as tabs in that pane
}

PANE_DROP_LABELS := [Pane_Drop]string {
	.None          = "",
	.Paste_Path    = "Paste path",
	.Insert_Prompt = "Insert into prompt",
	.Open_Here     = "Open here",
}

// What a pane shows, as a drop sees it.
Pane_Drop_Tab :: enum u8 {
	Nothing, // no pane under the pointer
	Empty, // a pane with no tab
	Terminal, // a shell, running
	Agent, // pi or Claude Code, running
	Codex, // Codex, running
	Document, // an editor, Markdown, browser, Changes or app tab
	Exited, // a terminal or agent whose program is not running (or has no terminal yet)
}

pane_drop_tab_of :: proc(tab: ^Tab) -> Pane_Drop_Tab {
	if tab == nil do return .Empty
	live := tab.status == .Running && tab.has_term
	switch k in tab.kind {
	case Shell_Tab:  return live ? .Terminal : .Exited
	case Pi_Tab:     return live ? .Agent : .Exited
	case Claude_Tab: return !live ? .Exited : harness_is_codex(k.harness) ? .Codex : .Agent
	case Editor_Tab, Markdown_Tab, Browser_Tab, Changes_Tab, App_Tab: return .Document
	}
	return .Nothing
}

pane_drop_action :: proc(t: Pane_Drop_Tab) -> Pane_Drop {
	switch t {
	case .Terminal:        return .Paste_Path
	case .Agent, .Codex:   return .Insert_Prompt
	case .Empty, .Document: return .Open_Here
	case .Nothing, .Exited: return .None
	}
	return .None
}

// The text a Paste_Path or Insert_Prompt sends (temp): every path, a space after each. A
// terminal's are shell-quoted; a prompt's are plain, quoted only when they must be (a space or a
// quote in it, or a word starting / ! $ or @, which an agent's empty prompt may read as a command
// or a picker: every dragged path starts /). err: why nothing goes (a control character in a name: a newline would press Enter).
pane_drop_text :: proc(action: Pane_Drop, tab: Pane_Drop_Tab, paths: []string) -> (text, err: string) {
	if action != .Paste_Path && action != .Insert_Prompt do return "", "nothing to type"
	if len(paths) == 0 do return "", "nothing to drop"
	b := strings.builder_make(context.temp_allocator)
	for p in paths {
		for i in 0 ..< len(p) do if p[i] < 0x20 || p[i] == 0x7f do return "", "a name has a control character"
		quote := action == .Paste_Path || strings.index_any(p, " \t'\"\\`$") >= 0
		if action == .Insert_Prompt && len(p) > 0 && strings.index_byte("/!$@", p[0]) >= 0 do quote = true
		strings.write_string(&b, quote ? drop_shell_quote(p) : p)
		strings.write_byte(&b, ' ')
	}
	return strings.to_string(b), ""
}

// 'path' for a POSIX shell (a ' inside becomes '\''). Temp.
drop_shell_quote :: proc(s: string) -> string {
	q, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return strings.concatenate({"'", q, "'"}, context.temp_allocator)
}

// The folder a Finder drop onto the tree copies into: a folder row's own, a file row's folder,
// the root below the rows. ok false (not on the list) or a row not of this tree: "".
files_finder_drop_dir :: proc(root, over: string, over_dir, ok: bool) -> string {
	if !ok || root == "" do return ""
	if over == "" do return root
	if !within(over, root) do return ""
	return over_dir ? over : tdir(over)
}

Files_Drop_Copy :: struct {
	from, to: string,
}

// One copy per dropped path (repeats and empty ones once; a trailing / ignored), each into dir by
// its own name. Temp.
files_finder_drop_copies :: proc(paths: []string, dir: string) -> []Files_Drop_Copy {
	out := make([dynamic]Files_Drop_Copy, context.temp_allocator)
	seen := make(map[string]bool, len(paths), context.temp_allocator)
	for p in paths {
		q := strings.trim_right(p, "/")
		if q == "" || q in seen do continue
		seen[q] = true
		append(&out, Files_Drop_Copy{from = q, to = strings.concatenate({dir, "/", filepath.base(q)}, context.temp_allocator)})
	}
	return out[:]
}
