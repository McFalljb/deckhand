#!/usr/bin/env python3
"""Tests for tests/scenes.py: the --changed selection and the build freshness check (./build.sh test
runs it; no git, no app). Run with python3 -B (no __pycache__ in tests/)."""
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
        for f in ("src/core/term.odin", "src/core/pty_posix.odin", "src/core/socket.odin", "src/core/persist.odin"):
            self.assertTrue(any(scenes.fnmatch.fnmatchcase(f, g) for g in self.special["@all"]), f)


class Freshness(unittest.TestCase):
    """The build is skipped only when nothing it is built from changed, was added or was deleted."""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="scenes-test-")
        self.root, scenes.ROOT = scenes.ROOT, self.tmp
        os.makedirs(os.path.join(self.tmp, "src"))
        os.makedirs(os.path.join(self.tmp, "build"))
        for f in ("src/a.odin", "src/b.odin"):
            self.write(f, "x", -100)
        self.write("build/out", "built", -50)
        scenes.record_inputs("build/out", ["src"])

    def tearDown(self):
        import shutil
        scenes.ROOT = self.root
        shutil.rmtree(self.tmp)

    def write(self, rel, text, age):
        import time
        p = os.path.join(self.tmp, rel)
        with open(p, "w") as fh:
            fh.write(text)
        t = time.time() + age
        os.utime(p, (t, t))

    def test_fresh(self):
        self.assertEqual(scenes.stale_input("build/out", ["src"]), "")

    def test_a_newer_file(self):
        self.write("src/b.odin", "y", 0)
        self.assertEqual(scenes.stale_input("build/out", ["src"]), "src/b.odin")

    def test_a_deleted_file(self):
        os.remove(os.path.join(self.tmp, "src/b.odin"))
        self.assertNotEqual(scenes.stale_input("build/out", ["src"]), "")

    def test_an_old_file_added(self):  # e.g. a checkout that restores a file with its old date
        self.write("src/c.odin", "z", -100)
        self.assertNotEqual(scenes.stale_input("build/out", ["src"]), "")

    def test_a_new_test_file_does_not_count(self):
        self.write("src/c_test.odin", "t", 0)
        self.assertEqual(scenes.stale_input("build/out", ["src"]), "")

    def test_vendor_and_assets_are_inputs(self):
        for top in ("vendor", "assets", "scripts/entitlements", "docs/GUIDE.md"):
            self.assertIn(top, scenes.APP_INPUTS)


class RunnerLimits(unittest.TestCase):
    """A scene killed for its timeout is not tried again, and a run's time budget leaves the rest
    unstarted (the summary always prints before CI's job timeout)."""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="scenes-test-")
        self.logs, scenes.LOGS = scenes.LOGS, self.tmp

    def tearDown(self):
        import shutil
        scenes.LOGS = self.logs
        shutil.rmtree(self.tmp)

    def scene(self, name, command):
        return scenes.Scene(name, "full", set(), 1, [], command)

    def test_a_killed_scene_is_not_retried(self):
        import io, contextlib
        r = scenes.Runner([self.scene("hang", "sleep 30")], 1, 1, 1, 1)
        with contextlib.redirect_stdout(io.StringIO()):
            r.run()
        res = r.results["hang"]
        self.assertEqual(res["result"], "FAIL")
        self.assertTrue(res["killed"])
        self.assertEqual(len(res["times"]), 1, "no second try after a timeout kill")

    def test_the_budget_leaves_the_rest_unstarted(self):
        import io, contextlib, time
        r = scenes.Runner([self.scene("a", "sleep 3"), self.scene("b", "true")], 1, 1, 0, 0,
                          budget=1.0)
        t0 = time.monotonic()
        with contextlib.redirect_stdout(io.StringIO()):
            r.run()
        self.assertLess(time.monotonic() - t0, 2.5, "the running scene is stopped at the budget")
        self.assertEqual(r.results["a"]["result"], "FAIL")
        self.assertEqual(r.results["b"]["result"], "NOT RUN")


if __name__ == "__main__":
    unittest.main()
