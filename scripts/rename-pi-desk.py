#!/usr/bin/env python3
"""The mechanical half of the pi-desk -> Deckhand rename (PR A, the 0.1.7 bridge).

Re-runnable and idempotent: run it on a tree, commit the result, then put the hand-written
compatibility commits on top. When main moves, reset to main, run it again and re-apply the
hand commits, instead of resolving conflicts by hand. A second run on its own output changes
nothing.

    scripts/rename-pi-desk.py            # rewrite the tree (git-tracked files, vendor/ excluded)
    scripts/rename-pi-desk.py --check    # exit 1 and list the files a run would change
    scripts/rename-pi-desk.py --stats    # per-category counts of what a run would change

What it does NOT rename (on purpose; the PR "Rename, part 1" lists the inventory):
- names of the old product itself: pi-desk.app, the 0.1.x runtime dir and socket names the
  instance guard looks for, the old Atlas prompt starters, the "Coming from pi-desk" / "From
  pi-desk to Deckhand" sections;
- what PR B (0.1.8) changes: the bundle id dev.pi-desk.app and the signed-update format heads
  ("pi-desk update v2", "pi-desk-update-sig v2");
- the `pi-desk` command alias (bin/pi-desk, Bash(pi-desk ...) rules, the read-only guard's alias
  matching) and the old names the compat code reads or sets (those lines are in the hand
  commits, which come after this script).
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SELF = "scripts/rename-pi-desk.py"

# Files never touched (relative paths, regexes on the whole path).
EXCLUDE = [
    r"^vendor/",
    r"^" + re.escape(SELF) + r"$",
    r"^integrations/claude-code/bin/pi-desk$",  # the old alias itself
    r"\.(png|jpg|jpeg|gif|ico|icns|ttf|otf|woff2?|a|o|dylib|zip|gz|pdf)$",
    r"^integrations/pi/package-lock\.json$",
]

# Spans never rewritten, anywhere (old-product names and PR B items).
PROTECT_GLOBAL = [
    r"dev\.pi-desk\.app",  # bundle id: PR B
    r"pi-desk update v2",  # signed manifest head: PR B
    r"pi-desk-update-sig v2",  # signature file head: PR B
    r"pi-desk\.app",  # the old app bundle (instance guard, the move notes)
    r"pi-desk 0\.1\.x",  # the old product's releases
    r"pi-desk-0\.1\.\d+-macos-arm64[\w.]*",  # old release assets
    r"Bash\(pi-desk[^)]*\)",  # the kept alias's allowed-tools rules
    r"bin/pi-desk\b(?!-)",  # the kept alias file
    r"PI-DESK|Pi-Desk(?:-Cli)?",  # case-insensitive alias tests
    r"ATLAS_PROMPT_STARTER_V[12]",
    r"pi-desk session titles 2",  # titles.txt's format line: a saved file's header
    r"#coming-from-pi-desk|#from-pi-desk-to-deckhand",  # anchors of kept headings
    r"(?i)Coming from pi-desk|From pi-desk to Deckhand",
    r"used to be called pi-desk",
    r"Deckhand's old name, pi-desk",
    r"pi-desk \(its old name, an alias\)",
    r"`deckhand` or `pi-desk`",  # the kept alias, beside the new name
    r"pi-desk jobs approval key",  # the old Keychain item's name
    r"\$TMPDIR/pi-desk-<uid>",  # the 0.1.x runtime dir, named as it was
    r"build/pi-desk(?![-.\w])",  # the old build wrapper, kept one more release
]

# Per file: extra spans kept (regexes), for the old-product lines in code.
PROTECT_FILE = {
    "src/core/instance.odin": [
        r"pi-desk-<uid>", r'"pi-desk-"', r'"pi-desk"', r"pi-desk is (?:running|using)[^\"]*", r"Quit pi-desk first",
        r"running pi-desk\b", r"pi-desk 0\.1", r"pi-desk-<pid>\.sock", r"\bold pi-desk\b",
    ],
    "src/core/instance_test.odin": [r"[\w/.$%-]*pi-desk[\w/.$%-]*", r"pi-desk"],
    "src/core/socket_posix.odin": [r"pi-desk-%d", r"/pi-desk\"", r"pi-desk-<uid>", r"/pi-desk,", r"pi-desk 0\.1\.x",
                               r"running pi-desk", r"XDG_RUNTIME_DIR/pi-desk"],
    "src/core/runtime_dir_test.odin": [r"pi-desk-\d+", r"pi-desk-%d", r"/pi-desk\b"],
    "src/main.odin": [r"running pi-desk", r"pi-desk 0\.1"],
    # The read-only guard matches the kept `pi-desk` / `pi-desk-cli` command words.
    "tools/pi-desk-cli/readonly.odin": [r'"pi-desk"', r'len\("pi-desk"\)', r'"-cli"', r"`pi-desk` \(its old name, an alias\) or `pi-desk-cli`"],
    "tools/pi-desk-cli/cli_test.odin": [r'"pi-desk"', r"\bpi-desk(?:-cli)? (?=[a-z])", r"deckhand or pi-desk", r"pi-desk ones",
                                        r'len\("pi-desk"\)'],
    "src/sidebar_test.odin": [r"pi-desk"],
    "src/folders_test.odin": [r"pi-desk"],  # makes ~/pi-desk and checks the path it expands to
    # a project folder named pi-desk (polish.sh makes it, polish.txt renames it and checks the text)
    "tests/scripts/polish.txt": [r"pi-desk"],
    "tests/scripts/polish.sh": [r"pi-desk"],
    "tests/web/polish.html": [r"pi-desk download fixture"],  # its size (25 bytes) is checked
    # pi tabs never get pi-kit's PI_DESK_ bridge variables: the fake Atlas counts them (0)
    "tests/scripts/fake-atlas.py": [r'"PI_DESK_"', r"pi-desk env", r"pi-kit's PI_DESK_\*", r"PI_DESK_ the same"],
    "tests/scripts/agent.txt": [r"pi-desk env"],  # a project named pi-desk: the filter's fixture
    "docs/ROADMAP.md": [r"`~/pi-desk`, or any folder"],
    "integrations/claude-code/skills/deckhand/SKILL.md": [r"`pi-desk` still works as an alias"],
    "tools/pi-desk-cli/manual.md": [r"`pi-desk` still works as an alias"],
    "integrations/claude-code/README.md": [r"`pi-desk` \(`bin/pi-desk`\) is a kept alias"],
    "tests/readonly-vectors.json": [r"pi-kit's MUTATING"],
    "src/core/claude_reload.odin": [r'"bin/pi-desk"'],
    # pi-kit's own bridge variables: pi tabs never get them (an installed pi-kit's desk extensions
    # switch on with them), and the tests say so. Not Deckhand's to rename.
    r"^(integrations/pi/|src/pi_integration(_test)?\.odin$|tests/scripts/pi-chat-readonly\.sh$)": [
        r"\bPI_DESK_(?:SOCKET|TOKEN|CONTROL_TOKEN|SHOTS_DIR)\b", r"\bPI_DESK_\*", r"pi-kit's PI_DESK_DATA_DIR",
    ],
    r"^integrations/pi/test/unit\.test\.ts$": [r"\bPI_DESK_DATA_DIR\b"],
    r"^integrations/pi/test/optional\.test\.ts$": [r"^.*doesNotMatch\(text, /pi-desk.*$", r"^.*pi-kit's desk skill \(pi-desk\).*$"],
    # ~/Deckhand, or ~/pi-desk when only that one is there (already done before the rename)
    "src/ui_setup.odin": [r'"%s/pi-desk"', r"~/pi-desk when", r"made by pi-desk"],
}

# Whole blocks kept verbatim: (path regex, start line regex, end line regex; end line excluded).
KEEP_BLOCKS = [
    (r"^src/agent\.odin$", r"^// The starter until the rename to Deckhand", r"^// The agent in State"),
    (r"^README\.md$", r"^### Coming from pi-desk", r"^#{1,3} "),
    (r"^docs/GUIDE\.md$", r"^### From pi-desk to Deckhand", r"^#{1,3} "),
    (r"^SECURITY\.md$", r"earlier pi-desk 0\.1\.x builds", r"^\s*$"),
]

# The renames, in order (first match wins per span). Each: (category, regex, replacement).
RULES = [
    # --- B: names users and other tools see (compat code is in the hand commits) ---
    ("B data dir", r"Application Support/pi-desk", "Application Support/Deckhand"),
    ("B data dir", r"(\.local/share|XDG_DATA_HOME)/pi-desk\b", r"\1/deckhand"),
    ("B CEF cache", r"Library/Caches/pi-desk", "Library/Caches/deckhand"),
    ("B release key", r"\.config/pi-desk", ".config/deckhand"),
    ("B project file", r"\.pi-desk/", ".deckhand/"),
    ("B project file", r'"\.pi-desk"', '".deckhand"'),
    ("B TERM_PROGRAM", r"TERM_PROGRAM=pi-desk", "TERM_PROGRAM=Deckhand"),
    ("B hello app", r'"app":"pi-desk"', '"app":"deckhand"'),
    ("B CLI binary", r"pi-desk-cli", "deckhand-cli"),
    ("B CLI binary", r"\bpi_desk_cli\b", "deckhand_cli"),
    # env vars: test hooks, build knobs and the tab/job contract alike (dual-set by hand)
    ("A/B env", r"PI_DESK_", "DECKHAND_"),  # no \b: "\x00PI_DESK_SCRIPT" in tests
    ("A/B env", r"\bPI_DESK\b", "DECKHAND"),
    # --- A: internal names ---
    ("A test scheme", r'to16\("pidesk-test", 11,', 'to16("deckhand-test", 13,'),  # its length (cef_helper.c)
    ("A test scheme", r"\bpidesk-test\b", "deckhand-test"),
    ("A test scheme", r"\bpidesk://", "deckhand://"),
    ("A UI row ids", r"\bpi-desk:(?=[a-z\"])", "deckhand:"),
    ("A Mach names", r"dev\.pi-desk\.frames", "dev.deckhand.frames"),
    ("A Mach names", r"\bpi-desk\.fswatch", "deckhand.fswatch"),
    ("A build outputs", r"build/pi-desk(?=[-\s\"'`)]|$)", "build/deckhand"),
    ("A symbols", r"\binstance_old_pidesk_find\b", "instance_legacy_find"),
    ("A symbols", r"\binstance_old_pidesk\b", "instance_legacy"),
    ("A symbols", r"\binstance_pidesk_exe\b", "instance_legacy_exe"),
    ("A symbols", r"PIDESK", "DECKHAND"),
    ("A symbols", r"pidesk", "deckhand"),
    ("A symbols", r"\b__pi_desk_", "__deckhand_"),
    ("A symbols", r"pi_desk", "deckhand"),
    ("A native prefix", r"(?<![A-Za-z0-9_])pd_", "dh_"),
    ("A native prefix", r"(?<![A-Za-z0-9_])PD_", "DH_"),
    ("A native prefix", r"(?<=-D)PD_", "DH_"),  # -DPD_RELEASE=1
    ("A comments fence", r"pi-desk-comments", "deckhand-comments"),
    # paths, temp names, identifiers: lower case
    ("A identifiers", r"(?<=~/)pi-desk\b", "Deckhand"),  # the default main folder, ~/Deckhand
    ("A identifiers", r"(?<=[/._$-])pi-desk\b", "deckhand"),
    ("A identifiers", r"\bpi-desk(?=[-_./])", "deckhand"),
    ("A identifiers", r'(?<=")pi-desk(?=")', "deckhand"),
    ("A identifiers", r"(?<=updated_by: )pi-desk\b", "deckhand"),
    # the command: `pi-desk`, `pi-desk hook readonly`, "pi-desk tabs: ..."
    ("A command word", r"(?<=`)pi-desk(?=[` ])", "deckhand"),
    ("A command word", r"\bpi-desk (?=(?:tabs|read|screenshot|state|show|click|type|press|upload|hook|comments|"
     r"app (?:call|screenshot|list-declared|open|close|restart|input|events))\b)", "deckhand "),
    # what is left is prose: the product's name
    ("A prose", r"\bpi-desk\b", "Deckhand"),
]

FILE_RENAMES = [("tools/pi-desk-cli", "tools/deckhand-cli")]

COMPILED = [(c, re.compile(p), r) for c, p, r in RULES]
PROT_G = [re.compile(p) for p in PROTECT_GLOBAL]
PROT_F = [(re.compile(k if k.startswith("^") else "^" + re.escape(k) + "$"), [re.compile(p) for p in v])
          for k, v in PROTECT_FILE.items()]
EXCL = [re.compile(p) for p in EXCLUDE]


def tracked() -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True).stdout
    return [p for p in out.decode().split("\0") if p]


def protect_spans(line: str, pats) -> list[tuple[int, int]]:
    spans = []
    for p in pats:
        for m in p.finditer(line):
            if m.end() > m.start():
                spans.append((m.start(), m.end()))
    spans.sort()
    merged: list[tuple[int, int]] = []
    for s, e in spans:
        if merged and s <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(e, merged[-1][1]))
        else:
            merged.append((s, e))
    return merged


def rewrite_seg(seg: str, stats: dict) -> str:
    for cat, rx, rep in COMPILED:
        seg, n = rx.subn(rep, seg)
        if n:
            stats[cat] = stats.get(cat, 0) + n
    return seg


def rewrite_line(line: str, pats, stats: dict) -> str:
    if not re.search(r"(?i)pi-desk|pi_desk|pidesk|pd_", line):
        return line
    out, pos = [], 0
    for s, e in protect_spans(line, pats):
        out.append(rewrite_seg(line[pos:s], stats))
        out.append(line[s:e])
        pos = e
    out.append(rewrite_seg(line[pos:], stats))
    return "".join(out)


def rewrite_text(path: str, text: str, stats: dict) -> str:
    # Rules and protections use the path the file has after the rename.
    key = path
    for old, new in FILE_RENAMES:
        if key.startswith(new + "/"):
            key = old + key[len(new):]
    pats = PROT_G + [p for rx, ps in PROT_F if rx.search(key) for p in ps]
    blocks = [(re.compile(s), re.compile(e)) for f, s, e in KEEP_BLOCKS if re.search(f, key)]
    lines = text.split("\n")
    keep_end = None
    for i, line in enumerate(lines):
        if keep_end is not None:
            if not keep_end.search(line):
                continue
            keep_end = None
        for s, e in blocks:
            if s.search(line):
                keep_end = e
                break
        if keep_end is not None:
            continue  # a block's first line is kept too
        lines[i] = rewrite_line(line, pats, stats)
    return "\n".join(lines)


def main() -> int:
    check = "--check" in sys.argv
    show_stats = "--stats" in sys.argv
    dry = check or show_stats
    stats: dict = {}
    changed = []
    if not dry:
        for old, new in FILE_RENAMES:
            if (ROOT / old).exists() and not (ROOT / new).exists():
                subprocess.run(["git", "mv", old, new], cwd=ROOT, check=True)
    for path in tracked():
        if any(x.search(path) for x in EXCL):
            continue
        f = ROOT / path
        if not f.is_file() or f.is_symlink():
            continue
        try:
            text = f.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        new = rewrite_text(path, text, stats)
        if new != text:
            changed.append(path)
            if not dry:
                f.write_text(new, encoding="utf-8")
    if show_stats:
        for k in sorted(stats):
            print(f"{stats[k]:6d}  {k}")
        print(f"{sum(stats.values()):6d}  total, in {len(changed)} files")
    if check:
        for p in changed:
            print(p)
        pending = [o for o, n in FILE_RENAMES if (ROOT / o).exists()]
        return 1 if changed or pending else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
