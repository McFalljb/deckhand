package core

// files_drops.odin: what a Files-tree drag released over a pane does (by what the pane shows),
// the text it pastes or inserts, and where a Finder drop onto the tree copies to.

import "core:testing"

@(test)
pane_drop_by_tab_kind :: proc(t: ^testing.T) {
	// what the pane shows -> what a release there does
	testing.expect_value(t, pane_drop_action(.Empty), Pane_Drop.Open_Here)
	testing.expect_value(t, pane_drop_action(.Terminal), Pane_Drop.Paste_Path)
	testing.expect_value(t, pane_drop_action(.Agent), Pane_Drop.Insert_Prompt)
	testing.expect_value(t, pane_drop_action(.Codex), Pane_Drop.Insert_Prompt)
	testing.expect_value(t, pane_drop_action(.Document), Pane_Drop.Open_Here)
	testing.expect_value(t, pane_drop_action(.Exited), Pane_Drop.None)
	testing.expect_value(t, pane_drop_action(.Nothing), Pane_Drop.None)

	// tabs -> what the pane shows
	tab :: proc(kind: Tab_Kind, status: Tab_Status = .Running, has_term := true) -> Tab {
		return Tab{kind = kind, status = status, has_term = has_term}
	}
	testing.expect_value(t, pane_drop_tab_of(nil), Pane_Drop_Tab.Empty)
	x := tab(Shell_Tab{})
	testing.expect_value(t, pane_drop_tab_of(&x), Pane_Drop_Tab.Terminal)
	x = tab(Shell_Tab{}, .Exited)
	testing.expect_value(t, pane_drop_tab_of(&x), Pane_Drop_Tab.Exited)
	x = tab(Shell_Tab{}, .Running, false) // no terminal (yet)
	testing.expect_value(t, pane_drop_tab_of(&x), Pane_Drop_Tab.Exited)
	x = tab(Pi_Tab{})
	testing.expect_value(t, pane_drop_tab_of(&x), Pane_Drop_Tab.Agent)
	x = tab(Pi_Tab{}, .Not_Started)
	testing.expect_value(t, pane_drop_tab_of(&x), Pane_Drop_Tab.Exited)
	x = tab(Claude_Tab{harness = .Claude})
	testing.expect_value(t, pane_drop_tab_of(&x), Pane_Drop_Tab.Agent)
	x = tab(Claude_Tab{harness = .Codex})
	testing.expect_value(t, pane_drop_tab_of(&x), Pane_Drop_Tab.Codex)
	for k in ([]Tab_Kind{Editor_Tab{}, Markdown_Tab{}, Browser_Tab{}, Changes_Tab{}, App_Tab{}}) {
		x = tab(k, .Running, false)
		testing.expect_value(t, pane_drop_tab_of(&x), Pane_Drop_Tab.Document)
	}
	testing.expect_value(t, PANE_DROP_LABELS[.Paste_Path], "Paste path")
	testing.expect_value(t, PANE_DROP_LABELS[.Insert_Prompt], "Insert into prompt")
	testing.expect_value(t, PANE_DROP_LABELS[.Open_Here], "Open here")
}

@(test)
pane_drop_texts :: proc(t: ^testing.T) {
	// a terminal: each path shell-quoted, a space after each (as the drop always pasted)
	s, err := pane_drop_text(.Paste_Path, .Terminal, {"/p/a.txt", "/p/it's dir"})
	testing.expect_value(t, err, "")
	testing.expect_value(t, s, `'/p/a.txt' '/p/it'\''s dir' `)
	// an agent's prompt: the plain path, quoted only when it has to be; spaces between, one after
	s, err = pane_drop_text(.Insert_Prompt, .Agent, {"/p/a.txt", "/p/b c.md", "rel/x", "!x"})
	testing.expect_value(t, err, "")
	// a word starting / ! $ or @ (every dragged path starts /) could read as a command in an empty prompt: quoted
	testing.expect_value(t, s, `'/p/a.txt' '/p/b c.md' rel/x '!x' `)
	// Codex: a word starting / ! $ or @ would be a command or open a picker: quoted
	s, err = pane_drop_text(.Insert_Prompt, .Codex, {"/p/a.txt", "rel/x", "@types/y"})
	testing.expect_value(t, err, "")
	testing.expect_value(t, s, `'/p/a.txt' rel/x '@types/y' `)
	testing.expect_value(t, codex_command_text(s), "")
	// a control character in a name (a newline would press Enter): nothing is sent
	_, err = pane_drop_text(.Insert_Prompt, .Agent, {"/p/a\nb"})
	testing.expect(t, err != "", "a newline refused")
	_, err = pane_drop_text(.Paste_Path, .Terminal, {"/p/a\x1bb"})
	testing.expect(t, err != "", "an escape refused")
	// nothing to send
	_, err = pane_drop_text(.Paste_Path, .Terminal, {})
	testing.expect(t, err != "", "nothing")
	_, err = pane_drop_text(.Open_Here, .Document, {"/p/a"})
	testing.expect(t, err != "", "no text for Open here")
}

@(test)
finder_drop_target_and_copies :: proc(t: ^testing.T) {
	root := "/w/proj"
	testing.expect_value(t, files_finder_drop_dir(root, "/w/proj/src", true, true), "/w/proj/src") // a folder row: into it
	testing.expect_value(t, files_finder_drop_dir(root, "/w/proj/src/a.go", false, true), "/w/proj/src") // a file row: its folder
	testing.expect_value(t, files_finder_drop_dir(root, "", false, true), root) // below the rows: the root
	testing.expect_value(t, files_finder_drop_dir(root, "/w/proj/src", true, false), "") // not on the list
	testing.expect_value(t, files_finder_drop_dir("", "", false, true), "") // no tree
	testing.expect_value(t, files_finder_drop_dir(root, "/elsewhere/x", false, true), "") // a row not of this tree

	cs := files_finder_drop_copies({"/Users/me/Desktop/a.txt", "/Users/me/pics", "", "/Users/me/Desktop/a.txt", "/Users/me/pics/"}, "/w/proj/src")
	testing.expect_value(t, len(cs), 2)
	testing.expect_value(t, cs[0].from, "/Users/me/Desktop/a.txt")
	testing.expect_value(t, cs[0].to, "/w/proj/src/a.txt")
	testing.expect_value(t, cs[1].from, "/Users/me/pics")
	testing.expect_value(t, cs[1].to, "/w/proj/src/pics")
	testing.expect_value(t, len(files_finder_drop_copies({"/"}, "/w/proj")), 0) // no name to copy as
}
