#!/usr/bin/env python3
"""A test stops only the processes it started. Every pkill in tests/ (its scenes and scripts) names
something of the test's own: its runtime or work dir ($RUN, $RUN2, $r, $W, a Python test's
dirs.run), a test-only program ($ROOT/tests/...), or a parent pid it holds (-P "$pid"). A bare
pattern such as "deckhand-core-serve connect" or "$ROOT/build/deckhand" also matches the Deckhand
the developer is using (its core, holder and machine connections), which `./build.sh scenes
--changed` would then kill. killall (a name for every process of that name) is refused outright.
./build.sh test and CI run this.

Usage: scripts/check-scoped-kills.py [--root DIR]   (exit 1 and one line per bad kill; DIR: the repo)
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
if len(sys.argv) == 3 and sys.argv[1] == "--root":
    ROOT = pathlib.Path(sys.argv[2]).resolve()

KILL = re.compile(r"\b(pkill|killall)\b")
# what makes a pkill this test's own: its dirs, its own programs, or a parent pid it holds
SCOPED = re.compile(
    r"\$\{?(RUN\d*|r|W)\b"            # the test's runtime dirs and work dir
    r"|\$\{?ROOT\}?/tests/"           # a test-only program (a fake pi, a fake bridge)
    r"|\bdirs\.run\b"                 # a Python test's runtime dir
    r"|-P\s+\"?\$\{?\w+"              # the children of a pid the test holds
)
# the build's programs are the developer's too (./build.sh run): refused even beside a scoped
# alternative in the same pattern ("$ROOT/build/deckhand|$ROOT/tests/fake.py")
SHARED = re.compile(r"\$\{?ROOT\}?/build/")
# this check's own test plants bad kills in strings
SELF_TEST = "check-scoped-kills-test.sh"


def bad_lines(path: pathlib.Path):
    try:
        text = path.read_text()
    except (UnicodeDecodeError, OSError):
        return
    for no, line in enumerate(text.splitlines(), 1):
        code = line.lstrip()
        if code.startswith("#"):
            continue
        m = KILL.search(code)
        if not m:
            continue
        if m.group(1) == "killall":
            yield no, line.strip(), "killall stops every process of that name"
        elif SHARED.search(code):
            yield no, line.strip(), "pkill of the build's programs, which the developer may be running"
        elif not SCOPED.search(code):
            yield no, line.strip(), "pkill without this test's own dir, program or parent pid"


def main() -> int:
    tests = ROOT / "tests"
    files = sorted(p for p in tests.rglob("*") if p.is_file() and p.suffix in (".sh", ".py", ""))
    bad = 0
    for path in files:
        if "node_modules" in path.parts or path.name == SELF_TEST:
            continue
        for no, line, why in bad_lines(path):
            bad += 1
            print(f"{path.relative_to(ROOT)}:{no}: {why}: {line}")
    if bad:
        print(f"check-scoped-kills: {bad} kill(s) could reach processes the test did not start "
              "(scope them to the test's runtime dir, work dir or pids)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
