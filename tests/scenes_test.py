#!/usr/bin/env python3
"""Tests for tests/scenes.py's --changed selection (./build.sh test runs it; no git, no app)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenes  # noqa: E402

COMMANDS = """package main

run_command :: proc(c: Command) -> Result {
	switch x in c {
	case Worktree_Remove:
		p := find_project(x.project_id)
		if p == nil do return fail("no such project")
		return ok()
	case Browser_Open:
		return ok()
	}
}
"""


class CoreSelection(unittest.TestCase):
    def setUp(self):
        self.all, self.special = scenes.load()
        self.by_name = {s.name: s for s in self.all}

    def test_a_hunk_inside_a_case_names_its_case(self):
        lines = COMMANDS.split("\n")
        # line 7 ("if p == nil ...") is in case Worktree_Remove, in proc run_command
        names = scenes.enclosing_names(lines, 7)
        self.assertIn("worktree_remove", names)
        self.assertIn("run_command", names)

    def test_singular_matches_a_plural_stem(self):
        self.assertTrue(scenes.mentions("worktree_remove", "worktrees"))
        self.assertTrue(scenes.mentions("new_claude_session", "claude"))
        self.assertFalse(scenes.mentions("subworktree", "worktrees"))

    def test_an_edit_in_a_case_body_selects_its_area(self):
        # the changed line itself says nothing of worktrees; its case does
        text = "if p == nil do return fail(\"no such project\")\n" + "\n".join(
            scenes.enclosing_names(COMMANDS.split("\n"), 7))
        picked = [s.name for s in self.all if s.tier == "full" and scenes.core_pick(s, text)]
        self.assertIn("worktrees", picked)
        self.assertNotIn("browser-a", picked)

    def test_terminal_socket_and_persistence_select_everything(self):
        for f in ("src/term.odin", "src/pty_posix.odin", "src/socket.odin", "src/persist.odin"):
            self.assertTrue(any(scenes.fnmatch.fnmatchcase(f, g) for g in self.special["@all"]), f)


if __name__ == "__main__":
    unittest.main()
