package main

// Docs upkeep (`./build.sh test`): every user action and its shortcut is in
// the user guide (docs/GUIDE.md), and every command the user or agents may
// send is in the guide or the protocol (docs/PROTOCOL.md). A new action or
// command fails here until the docs mention it.

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
DOC_PROTOCOL :: #load("../docs/PROTOCOL.md", string)

@(test)
docs_cover_actions_and_commands :: proc(t: ^testing.T) {
	for a in ACTIONS {
		testing.expectf(t, strings.contains(ATLAS_GUIDE, a.label), "docs/GUIDE.md does not mention action %q (%s)", a.label, a.id)
		if a.keys != "" do testing.expectf(t, strings.contains(ATLAS_GUIDE, a.keys), "docs/GUIDE.md does not list shortcut %s (%s)", a.keys, a.id)
	}
	// the menu bar's own wording and shortcuts (menubar.odin)
	for it in menubar_items() {
		if it.title != "" do testing.expectf(t, strings.contains(ATLAS_GUIDE, it.title), "docs/GUIDE.md does not mention menu item %q", it.title)
		if it.keys != "" do testing.expectf(t, strings.contains(ATLAS_GUIDE, it.keys), "docs/GUIDE.md does not list shortcut %s (%s)", it.keys, it.title)
	}
	for top in MENUBAR do testing.expectf(t, strings.contains(ATLAS_GUIDE, fmt.tprintf("**%s**", top.title)), "docs/GUIDE.md has no **%s** menu", top.title)
	for x in SHORTCUTS_EXTRA do testing.expectf(t, strings.contains(ATLAS_GUIDE, x.keys), "docs/GUIDE.md does not list shortcut %s (%s)", x.keys, x.label)
	for s in COMMAND_SPECS {
		if s.who != .User && s.who != .Anyone do continue
		name := fmt.tprintf("`%s`", s.type)
		testing.expectf(t, strings.contains(ATLAS_GUIDE, name) || strings.contains(DOC_PROTOCOL, name), "neither docs/GUIDE.md nor docs/PROTOCOL.md mentions command %s", name)
	}
}
