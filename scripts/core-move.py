#!/usr/bin/env python3
"""M2-B (docs/plans/background-core.md §10.2): move the core into src/core/ (package core).

Mechanical and re-runnable: on a checkout of the tree before the move it gives the same result
each time, so a rebase is "check out the new base, run this again". It:

  1. moves the files scripts/core-files.txt names (src/<f>.odin) to src/core/<f>.odin with
     `git mv`, as package core, and fixes their relative paths (imports, foreign imports, #load).
     A listed file that is missing, or that imports a window package, is skipped (printed);
  2. runs `odin check src/core` and, for each name the core uses that a window file declares,
     moves that declaration into src/core/<window file>_core.odin: a type or a constant, or a
     proc or variable that MOVE_DECLS names, until the core builds alone. Anything else the core
     needs from the window is a blocker: printed, and the script stops (fix it before the move,
     in package main: a Window_Hooks entry, or move the code);
  3. moves each test of a moved file (src/<f>_test.odin, src/<f>_*_test.odin), of no file (the
     shared helpers) and TEST_FILES to src/core/, then puts back any that do not build there
     (they use window code);
  4. declares the window's `state: ^core.State` (src/state_view.odin, design §10.2 "Qualified
     names, no alias file"), then runs `odin check src` in every build configuration (CONFIGS)
     and puts `core.` before each name a window file uses that is now the core's (adding
     `import "core"`), writes `state^`/`state` where the window used State by value or took its
     address, and drops @(private) from a core declaration the window uses, until nothing more
     changes;
  5. rewrites the paths of moved files (src/x.odin -> src/core/x.odin) in the repository's
     scripts, docs and tests, and the scenes' area globs (tests/scenes.txt);
  6. applies the hand edits (scripts/core-move-hand.patch, if there is one; --no-hand skips
     it), then checks that everything builds in every configuration, the boundary
     (scripts/check-core-boundary.sh) and the scenes map (tests/scenes.py --check-map).

scripts/core-move-verify.py checks the result: with every added `core.` prefix, every moved
block and every rewritten path taken back out, the tree is the one before the move, apart from
the hand edits.

Usage: scripts/core-move.py [--no-hand] [--keep-going] [--list FILE]
  --keep-going   print the blockers of step 2 and go on (a trial run: the result does not build)
"""
import argparse
import collections
import fnmatch
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import odin_src as osrc  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
CORE = os.path.join(SRC, "core")
CORE_LIST = os.path.join(ROOT, "scripts", "core-files.txt")
HAND_PATCH = os.path.join(ROOT, "scripts", "core-move-hand.patch")
STATE_VIEW = os.path.join(SRC, "state_view.odin")

# Window-file declarations that move into the core although they are procs or variables (pure
# data and helpers the core uses), by name. A name the core does not need, or no longer finds in
# a window file, is ignored.
MOVE_DECLS = """
THEME_NAMES APPEARANCE_NAMES TEXT_SIZE_NAMES APP_STATUS_NAMES EDITOR_VIEW_NAMES
ACT_BUTTON_NAMES ACT_MOD_NAMES BROWSER_DOWNLOAD_OP_NAMES BROWSER_EDIT_OP_NAMES
BROWSER_ZOOM_STEP_NAMES
fuzzy_score git_run git_run_input git_toplevel run_bounded run_bounded_exit path_stat path_kind
looks_binary regular_or_missing disk_read_chunk ago px browser_url_normalize browser_url_redacted
md_is_markdown_path
""".split()

# Tests that move although their name matches no moved file
TEST_FILES = []
# Tests that build in the core but need the window when they run: they stay in src/
WINDOW_TESTS = [
    "claude_review2_test.odin",  # r2_agent_open_file: open_file goes to the window's tab host
    "persist_panes_test.odin",  # rescans need project_tidy_test.odin's @(init) (temp roots shown)
]

# Names the window writes without `core.`: step 4 declares them on the window side
UNPREFIXED = {"state"}

# The build configurations that compile different code (`when` branches, build tags): the
# default, each boolean #config switch in src/ flipped (-define:DECKHAND_CEF=true...), read from
# the source so a renamed switch needs no edit here, and Linux. The window's prefixes are found
# in all of them. Linux does not build today: only its undeclared core names count (the !darwin
# files).
def build_configs():
    out, seen = [[]], set()
    for dirpath, _, files in os.walk(os.path.join(ROOT, "src")):
        for f in sorted(files):
            if f.endswith(".odin"):
                for m in re.finditer(r"#config\((\w+),\s*(true|false)\)", read(os.path.join(dirpath, f))):
                    if m.group(1) not in seen and not dirpath.endswith(("holder", "holderwire", "trust")):
                        seen.add(m.group(1))
                        out.append([f"-define:{m.group(1)}={'false' if m.group(2) == 'true' else 'true'}"])
    return out


CONFIGS = []  # filled by main(): build_configs() + LINUX + [TEST_BUILD]
LINUX = [["-target:linux_arm64"]]
TEST_BUILD = ["@test-build"]  # a test build, not a check (odin_errors)
BUILDING = []  # the ones that must build in the end (all but Linux)
ODIN_TIMEOUT = 300
WINDOW_ONLY_IMPORTS = ("sokol", "clay", "vendor:stb", "vendor:darwin", "core:sys/darwin/Foundation")
# Files step 5 leaves alone: the move's own scripts, the vendored trees, the design docs (they
# describe the move and the code before it)
PATH_REWRITE_SKIP = ("vendor/", "docs/plans/", "scripts/core-move", "scripts/core-files.txt",
                     "scripts/odin_src.py")

STATE_VIEW_TEXT = """package main

import "core"

// The window's State (docs/plans/background-core.md §10.2, "Qualified names, no alias file"):
// the core's own today, so the window keeps writing state.x; M3 points it at the window's
// replica. Written by scripts/core-move.py.
state: ^core.State = &core.state
"""


def run(cmd, check=True, **kw):
    p = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, **kw)
    if check and p.returncode != 0:
        sys.exit(f"core-move: {' '.join(cmd)} failed:\n{p.stdout}{p.stderr}")
    return p


def odin_errors(pkg, extra):
    """[(file, offset, message)] from `odin check pkg`: the first 2000 (odin slows to a crawl
    reporting tens of thousands; the loops run again until nothing changes)."""
    if extra == TEST_BUILD:
        # `odin check` compiles `when ODIN_TEST` branches out: a test build sees them (tests'
        # @(init)s). It links too when nothing is wrong, so it runs last and once.
        out = os.path.join(ROOT, "build", ".core-move-test-probe")
        cmd = ["odin", "build", pkg, "-build-mode:test", "-out:" + out, "-json-errors",
               "-max-error-count:2000", "-define:DECKHAND_UPDATE_TEST=true"]
    else:
        cmd = ["odin", "check", pkg, "-json-errors", "-max-error-count:2000"] + extra
        if pkg.endswith("core"):
            cmd.append("-no-entry-point")
    try:
        p = run(cmd, check=False, timeout=ODIN_TIMEOUT)
    except subprocess.TimeoutExpired:
        sys.exit(f"core-move: `{' '.join(cmd)}` ran {ODIN_TIMEOUT} s (odin can hang on a global whose "
                 "type is undeclared, e.g. state_view.odin before State moved): stopped")
    text = p.stderr.strip() or p.stdout.strip()
    if not text:
        if p.returncode != 0:
            sys.exit(f"core-move: `{' '.join(cmd)}` failed with no errors (exit {p.returncode}: did odin crash?)")
        return []
    start = text.find("{")
    try:
        data = json.loads(text[start:])
    except ValueError:
        sys.exit(f"core-move: cannot read odin's errors:\n{text[:2000]}")
    out = []
    raw = {}
    for e in data.get("errors", []):
        if e.get("type", "error") != "error":
            continue  # warnings (an unused -define in the core alone)
        pos = e.get("pos") or {}
        f = os.path.realpath(pos.get("file", ""))
        off = pos.get("offset", -1)
        # odin's offsets count bytes; Python's strings count characters
        if off > 0 and os.path.isfile(f):
            if f not in raw:
                with open(f, "rb") as fh:
                    raw[f] = fh.read()
            off = len(raw[f][:off].decode("utf-8", errors="replace"))
        out.append((f, off, " ".join(e.get("msgs", []))))
    return out


def errors_all(pkg, cfgs):
    """[(cfg, file, offset, message)] over the configurations, one check at a time (each odin
    uses several cores already)."""
    return [(c, f, o, m) for c in cfgs for f, o, m in odin_errors(pkg, c)]


def is_linux(cfg):
    return bool(cfg) and cfg[0].startswith("-target")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def rel(p):
    return os.path.relpath(p, ROOT)


def line_of(f, off):
    try:
        t = read(f)
    except OSError:
        return f"{rel(f)}@{off}"
    return f"{rel(f)}:{t.count(chr(10), 0, max(off, 0)) + 1}"


def rel_fix(text, old_dir, new_dir, moved):
    """Rewrites the relative paths in imports, foreign imports and #load for a file that moved
    from old_dir to new_dir (moved: old absolute path -> new absolute path, for files that
    moved too)."""

    def fix(path):
        if ":" in path.split("/")[0] or path.startswith("/"):
            return path
        target = os.path.normpath(os.path.join(old_dir, path))
        target = moved.get(target, target)
        out = os.path.relpath(target, new_dir)
        return out

    def sub_import(m):
        return m.group(1) + '"' + fix(m.group(2)) + '"'

    text = re.sub(r'(?m)^(import[ \t]+(?:[A-Za-z_]\w*[ \t]+)?)"([^"]+)"', sub_import, text)

    def sub_foreign(m):
        inner = re.sub(r'"([^"]+)"', lambda q: '"' + fix(q.group(1)) + '"', m.group(2))
        return m.group(1) + inner

    text = re.sub(r'(?m)^([ \t]*foreign[ \t]+import[ \t]+\w+[ \t]*)(\{[^}]*\}|"[^"]*")', sub_foreign, text)
    text = re.sub(r'#load\("([^"]+)"', lambda m: '#load("' + fix(m.group(1)) + '"', text)
    return text


def window_files():
    return sorted(os.path.join(SRC, f) for f in os.listdir(SRC) if f.endswith(".odin"))


def core_files():
    return sorted(os.path.join(CORE, f) for f in os.listdir(CORE) if f.endswith(".odin"))


def index(files):
    """name -> (file, Decl) over the files' top-level declarations."""
    out = {}
    for f in files:
        text = read(f)
        for d in osrc.top_decls(text):
            if not d.file_private:  # @(private = "file"): no other file sees it
                out.setdefault(d.name, (f, d))
        # foreign procs inside `when` blocks (`when ODIN_OS == .Darwin { foreign lib { ... } }`)
        for m in re.finditer(r"(?m)^[ \t]+([A-Za-z_]\w*)[ \t]*::[ \t]*proc\b[^\n]*---", text):
            if m.group(1) not in out:
                out[m.group(1)] = (f, osrc.Decl(m.group(1), "proc", m.start(), m.end(), m.start(), 2, "when"))
                out[m.group(1)][1].file_private = False
    return out


def git_mv(a, b):
    run(["git", "mv", a, b])


def window_pkgs(text, imports_of=None):
    """The window packages text uses (its own imports, or imports_of's)."""
    used = pkgs_used(text)
    out = []
    for alias, path, _, _ in osrc.imports(imports_of if imports_of is not None else text):
        nm = osrc.import_name(alias, path)
        if nm in used and any(w in path for w in WINDOW_ONLY_IMPORTS):
            out.append(nm)
    return out


def pkgs_used(text):
    mask = osrc.code_mask(text)
    used = set()
    for m in re.finditer(r"\b([A-Za-z_]\w*)\.", text):
        if mask[m.start()] and (m.start() == 0 or text[m.start() - 1] != "."):
            used.add(m.group(1))
    return used


def links_shim(text):
    for m in re.finditer(r'(?m)^[ \t]*foreign[ \t]+import[ \t]+\w+[ \t]*(\{[^}]*\}|"[^"]*")', text):
        for lib in re.findall(r'"([^"]+)"', m.group(1)):
            if not lib.startswith("system:"):
                return lib
    return None


# --- step 1 -----------------------------------------------------------------------------------

def core_list():
    names = []
    for line in read(CORE_LIST).splitlines():
        names += line.split("#", 1)[0].split()
    dup = [n for n, c in collections.Counter(names).items() if c > 1]
    if dup:
        sys.exit(f"core-move: {rel(CORE_LIST)} names {', '.join(dup)} twice")
    return names


def step_move_files():
    os.makedirs(CORE, exist_ok=True)
    moved, skipped = {}, []
    for stem in core_list():
        src = os.path.join(SRC, stem + ".odin")
        if not os.path.exists(src):
            skipped.append(f"{stem}.odin (not in src/)")
            continue
        t = read(src)
        wp = [p for _, p, _, _ in osrc.imports(t) if any(w in p for w in WINDOW_ONLY_IMPORTS)]
        shim = links_shim(t)
        if wp or shim:
            skipped.append(f"{stem}.odin (a window file now: imports {', '.join(wp) or shim})")
            continue
        moved[src] = os.path.join(CORE, stem + ".odin")
    for a, b in moved.items():
        git_mv(a, b)
    for a, b in moved.items():
        t = read(b)
        t = re.sub(r"(?m)^package main\b", "package core", t, count=1)
        write(b, rel_fix(t, SRC, CORE, moved))
    for f in window_files():  # window files (and tests) that #load a moved file
        t = read(f)
        t2 = rel_fix(t, SRC, SRC, moved)
        if t2 != t:
            write(f, t2)
    print(f"core-move: moved {len(moved)} files to src/core/ ({rel(CORE_LIST)})")
    for s in skipped:
        print(f"  skipped {s}")
    return moved


# --- step 2: what the core needs from window files --------------------------------------------

class Mover:
    """Declarations taken out of window files into src/core/<stem>_core.odin. The window file
    is rewritten from its text before the move minus the spans; the core file is the blocks in
    their original order."""

    def __init__(self):
        self.orig = {}  # window file -> its text before any block left it
        self.spans = collections.defaultdict(list)  # window file -> [(head_start, end, name)]

    def text(self, wf):
        return self.orig[wf] if wf in self.orig else read(wf)

    def index(self):
        out = {}
        for f in window_files():
            for d in osrc.top_decls(self.text(f)):
                out.setdefault(d.name, (f, d))
        return out

    def take(self, wf, decl):
        if wf not in self.orig:
            self.orig[wf] = read(wf)
        if any(s == decl.head_start for s, _, _ in self.spans[wf]):
            return
        self.spans[wf].append((decl.head_start, decl.end, decl.name))
        self.spans[wf].sort()
        self.flush(wf)

    def flush(self, wf):
        text = self.orig[wf]
        keep, blocks = cut_blocks(text, [(s, e) for s, e, _ in self.spans[wf]])
        write(wf, keep)
        stem = os.path.basename(wf)[:-5]
        dest = os.path.join(CORE, stem + "_core.odin")
        body = "\n".join(blocks)
        used = pkgs_used(body)
        imps = []
        for alias, path, a, b in osrc.imports(text):
            if osrc.import_name(alias, path) in used:
                imps.append(rel_fix(text[a:b].rstrip("\n"), SRC, CORE, {}))
        write(dest, core_part_text(stem, imps, blocks))

    def all_blocks(self):
        return {wf: [n for _, _, n in sp] for wf, sp in self.spans.items()}


def cut_blocks(text, spans):
    """(text without the spans, [each span's text]); a blank line after a span that follows a
    blank line (or the file's start) goes with it, so no double blank lines are left behind.
    core-move-verify.py does the same cut."""
    keep, blocks, at = [], [], 0
    for s, e in sorted(spans):
        keep.append(text[at:s])
        blk = text[s:e]
        blocks.append(blk if blk.endswith("\n") else blk + "\n")
        at = e
        if text.startswith("\n", at) and (s == 0 or text[s - 1] == "\n") and (s < 2 or text[s - 2] == "\n"):
            at += 1
    keep.append(text[at:])
    return "".join(keep), blocks


def core_part_text(stem, imps, blocks):
    head = (f"package core\n\n// From src/{stem}.odin (scripts/core-move.py): the core uses these, the window keeps\n"
            f"// the rest of that file.\n\n")
    if imps:
        head += "\n".join(imps) + "\n\n"
    return head + "\n".join(b.rstrip("\n") + "\n" for b in blocks)


UNDECLARED = re.compile(r"Undeclared name: (\w+)")


def step_pull(mover, keep_going):
    move_decls = set(MOVE_DECLS)
    rounds = 0
    cfgs = CONFIGS[:1]  # the default configuration until it settles, then all (one at a time)
    while True:
        rounds += 1
        blockers = {}  # this round's: a name an earlier round could not move may be fine now
        wanted = collections.OrderedDict()
        others = []
        for cfg, f, off, msg in errors_all("src/core", cfgs):
            if not f.startswith(CORE + "/") or f.endswith("_test.odin"):
                continue
            m = UNDECLARED.search(msg)
            if not m:
                if not is_linux(cfg):
                    others.append((f, off, msg))
                continue
            wanted.setdefault(m.group(1), (cfg, f, off))
        idx = mover.index()
        cidx = index(core_files())
        took = 0
        for name, (cfg, f, off) in wanted.items():
            if name in cidx:
                continue  # declared in the core (another configuration's file): not the window's
            if name not in idx:
                if not is_linux(cfg):
                    blockers[name] = f"{name}: used by {line_of(f, off)}, declared nowhere in src/*.odin"
                continue
            wf, d = idx[name]
            ok = d.kind in ("type", "const") or name in move_decls
            where = f"({d.kind} in {rel(wf)}): used by {line_of(f, off)}"
            if not ok:
                blockers[name] = f"{name} {where}"
                continue
            if d.depth != 0:
                blockers[name] = f"{name} {where}, inside a top-level {d.block} block"
                continue
            text = mover.text(wf)
            wp = window_pkgs(text[d.start:d.end], text)
            if wp:
                blockers[name] = f"{name} {where}, uses {', '.join(wp)}"
                continue
            mover.take(wf, d)
            blockers.pop(name, None)
            took += 1
        if not took:
            if len(cfgs) < len(CONFIGS):
                cfgs = CONFIGS
                continue
            break
        if took and len(cfgs) > 1:
            cfgs = CONFIGS[:1]
        if rounds > 60:
            sys.exit("core-move: no progress pulling declarations into the core")
    n = sum(len(v) for v in mover.all_blocks().values())
    print(f"core-move: {n} declarations moved from window files into src/core/*_core.odin")
    for wf, names in sorted(mover.all_blocks().items()):
        print(f"  {os.path.basename(wf)}: {' '.join(names)}")
    if blockers:
        print(f"core-move: the core uses window code ({len(blockers)}; fix each before the move: a "
              "Window_Hooks entry, or move the code in package main):")
        for b in sorted(blockers.values()):
            print("  " + b)
        if not keep_going:
            sys.exit(2)
    elif others:
        print("core-move: the core has errors that are not undeclared names:")
        for f, off, msg in others[:40]:
            print(f"  {line_of(f, off)}: {msg}")
        if not keep_going:
            sys.exit(1)


# --- step 3: tests ----------------------------------------------------------------------------

def step_tests(moved, all_stems, keep_going):
    core_stems = {os.path.basename(b)[:-5] for b in moved.values()}
    cands = []
    for f in window_files():
        b = os.path.basename(f)
        if not b.endswith("_test.odin"):
            continue
        stem = b[: -len("_test.odin")]
        # the longest source file name the test's name starts with: panes_drag_test is
        # panes_drag's (a window file), panes_test panes' (the core's)
        owner = max((s for s in all_stems if stem == s or stem.startswith(s + "_")), key=len, default=None)
        # the core's tests, and tests of no file (shared helpers: tmpdir_test, cpu_clock_test...)
        if (owner in core_stems or owner is None or b in TEST_FILES) and b not in WINDOW_TESTS:
            cands.append(f)
    for f in cands:
        dst = os.path.join(CORE, os.path.basename(f))
        git_mv(f, dst)
        t = re.sub(r"(?m)^package main\b", "package core", read(dst), count=1)
        write(dst, rel_fix(t, SRC, CORE, moved))
    back = set()
    cfgs = BUILDING[:1]
    while True:
        bad = set()
        for cfg, f, off, msg in errors_all("src/core", cfgs):
            if f.startswith(CORE + "/") and f.endswith("_test.odin"):
                bad.add(f)
            elif f.startswith(CORE + "/") and not keep_going:
                sys.exit(f"core-move: a test move broke {line_of(f, off)}: {msg}")
        bad -= back
        if not bad:
            if len(cfgs) < len(BUILDING):
                cfgs = BUILDING
                continue
            break
        cfgs = BUILDING[:1]
        for f in sorted(bad):
            orig = os.path.join(SRC, os.path.basename(f))
            git_mv(f, orig)
            t = re.sub(r"(?m)^package core\b", "package main", read(orig), count=1)
            write(orig, rel_fix(t, CORE, SRC, {}))
            back.add(f)
    went = [f for f in cands if os.path.join(CORE, os.path.basename(f)) not in back]
    print(f"core-move: {len(went)} test files moved with their files; {len(back)} stay in src/ "
          f"(they use window code): {' '.join(sorted(os.path.basename(f) for f in back))}")
    return {f: os.path.join(CORE, os.path.basename(f)) for f in went}


# --- step 4: the window's prefixes --------------------------------------------------------------

STATE_TOKEN = re.compile(r"state\b")


def step_prefix():
    if "state" in index(core_files()):
        write(STATE_VIEW, STATE_VIEW_TEXT)
        run(["git", "add", rel(STATE_VIEW)])
    total = collections.Counter()
    # `x := state` copied State; with the pointer it would copy the pointer and still build:
    # it becomes `x := state^` before anything else
    if os.path.exists(STATE_VIEW):
        for f in window_files():
            t = read(f)
            t2, k = re.subn(r"(?m)^([ \t]*[A-Za-z_]\w*[ \t]*:=[ \t]*)state([ \t]*(//[^\n]*)?)$", r"\1state^\2", t)
            if k:
                write(f, t2)
                total["deref"] += k
    rounds = 0
    leftovers = []
    # the default configuration alone until it settles (most names are in every configuration),
    # then all of them
    cfgs = CONFIGS[:1]
    while True:
        rounds += 1
        cidx = index(core_files())
        # a name the window declares itself (in a `when` branch: update_test.odin's
        # UPDATE_TEST_PUBLIC_KEY) stays the window's; the other branch is a hand edit
        widx = window_names()
        own = {}
        inserts = collections.defaultdict(set)
        state_fix = collections.defaultdict(set)
        unprefix = collections.defaultdict(set)
        unexported = set()
        leftovers = []
        for cfg, f, off, msg in errors_all("src", cfgs):
            if not f.startswith(SRC + "/") or f.startswith(CORE + "/"):
                continue
            m = UNDECLARED.search(msg)
            if m and m.group(1) in cidx and m.group(1) not in UNPREFIXED and m.group(1) not in widx \
                    and m.group(1) not in own_names(f, own):
                inserts[f].add((off, m.group(1)))
                continue
            m3 = re.search(r"'(\w+)' is not declared by 'core'", msg)
            if m3:  # a prefix on a name odin called undeclared only because of another error
                unprefix[f].add((off, m3.group(1)))
                continue
            if "of type 'State' to '^State'" in msg and state_assign_at(f, off) is not None:
                state_fix[f].add(state_assign_at(f, off))
                continue
            m2 = re.search(r"'(\w+)' is not exported by 'core'", msg)
            if m2 and m2.group(1) in cidx:
                unexported.add(m2.group(1))
                continue
            if not is_linux(cfg) and "State" in msg and state_at(f, off):
                state_fix[f].add(off)
                continue
            if not is_linux(cfg):
                leftovers.append((f, off, msg))
        changed = 0
        if len({os.path.normcase(f) for f in inserts}) != len(inserts):
            sys.exit("core-move: odin named one file two ways: " + " ".join(sorted(inserts)))
        for f, offs in inserts.items():
            t = read(f)
            for off, name in sorted(offs, reverse=True):
                # the name must be there (an offset that does not point at it is never acted on)
                if t[max(off - 5, 0):off] != "core." and re.match(re.escape(name) + r"\b", t[off:off + len(name) + 1]):
                    t = t[:off] + "core." + t[off:]
                    changed += 1
                    total["prefix"] += 1
            write(f, add_core_import(t))
        for f, offs in unprefix.items():
            t = read(f)
            for off, name in sorted(offs, reverse=True):
                if t.startswith(name, off) and t[max(off - 5, 0):off] == "core.":
                    t = t[:off - 5] + t[off:]
                    changed += 1
                    total["prefix"] -= 1
            write(f, t)
        for f, offs in state_fix.items():
            t = read(f)
            for off in sorted(offs, reverse=True):
                t, kind = fix_state(t, off)
                if kind:
                    changed += 1
                    total[kind] += 1
            write(f, t)
        for name in sorted(unexported):
            cf_, d = cidx[name]
            t = read(cf_)
            seg = t[d.start:d.end]
            seg2 = re.sub(r"@\(private\)[ \t]*\n?", "", seg, count=1)
            if seg2 != seg:
                write(cf_, t[:d.start] + seg2 + t[d.end:])
                print(f"core-move: {name} ({rel(cf_)}) is used by the window: no longer @(private)")
                changed += 1
                total["private"] += 1
        if not changed:
            if len(cfgs) < len(CONFIGS):
                cfgs = CONFIGS
                continue
            break
        cfgs = CONFIGS[:1]
        if rounds > 80:
            sys.exit("core-move: no progress prefixing the window")
    print(f"core-move: window files: {total['prefix']} `core.` prefixes, {total['deref']} `state^`, "
          f"{total['addr']} `&state` -> `state`, {total['private']} @(private) dropped")
    return leftovers


def state_at(f, off):
    """The bare global `state` (not a field, not `state.x`) at or right after off."""
    t = read(f)
    o = off + 1 if t.startswith("&state", off) else off
    return t.startswith("state", o) and bool(STATE_TOKEN.match(t, o)) and (o == 0 or not re.match(r"[\w.]", t[o - 1]))


def state_assign_at(f, off):
    """`state = X` on off's line (odin points at X): the offset of that `state`, or None."""
    t = read(f)
    ls = t.rfind("\n", 0, off) + 1
    m = None
    for m in re.finditer(r"(?<![\w.])state(?=\s*=(?!=))", t[ls:off]):
        pass
    return ls + m.start() if m else None


def fix_state(t, off):
    # odin points at `state`, or at the `&` before it
    o = off + 1 if t.startswith("&state", off) else off
    if not t.startswith("state", o) or (o > 0 and re.match(r"[\w.]", t[o - 1])):
        return t, None
    after = t[o + 5:o + 6]
    if after in (".", "[", "^") or re.match(r"\w", after):
        return t, None
    if o > 0 and t[o - 1] == "&":
        return t[:o - 1] + t[o:], "addr"
    return t[:o + 5] + "^" + t[o + 5:], "deref"


def own_names(f, cache):
    if f not in cache:
        cache[f] = {d.name for d in osrc.top_decls(read(f))}
    return cache[f]


def window_names():
    """Names the window files declare (top level, and in top-level `when` and `foreign`
    blocks)."""
    return set(index(window_files()))


def add_core_import(t):
    if re.search(r'(?m)^import[ \t]+"core"', t):
        return t
    imps = osrc.imports(t)
    if imps:
        # after the core:/base: imports, before the relative ones
        at = imps[-1][3]
        for alias, path, a, b in imps:
            if ":" not in path:
                at = a
                break
        return t[:at] + 'import "core"\n' + t[at:]
    m = re.search(r"(?m)^package \w+[^\n]*\n", t)
    return t[: m.end()] + '\nimport "core"\n' + t[m.end():]


# --- step 5: paths in the rest of the repository --------------------------------------------

def step_paths(moved_all, old_src_files):
    """moved_all: old absolute path -> new absolute path (sources and tests)."""
    names = {rel(a): rel(b) for a, b in moved_all.items()}
    if not names:
        return
    pat = re.compile(r"(?<![\w.\-])(" + "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True)) + r")(?![\w])")
    files = run(["git", "ls-files"]).stdout.split()
    n_files = n_refs = 0
    for f in files:
        if f.startswith(PATH_REWRITE_SKIP) or not os.path.isfile(os.path.join(ROOT, f)):
            continue
        try:
            t = read(os.path.join(ROOT, f))
        except (UnicodeDecodeError, OSError):
            continue
        t2, k = pat.subn(lambda m: names[m.group(1)], t)
        if f == "tests/scenes.txt":
            t2 = scenes_globs(t2, set(names), set(names.values()), old_src_files)
            t2 = scenes_parts(t2, old_src_files)
        if t2 != t:
            write(os.path.join(ROOT, f), t2)
            n_files += 1
            n_refs += k
    print(f"core-move: {n_refs} paths of moved files rewritten in {n_files} files (scripts, docs, tests)")


def scenes_parts(text, old_src_files):
    """tests/scenes.txt: where an area names a window file whose declarations moved
    (src/x.odin -> src/core/x_core.odin), and state.odin (src/state_view.odin), the new file is
    named beside it."""
    parts = {}
    for f in sorted(os.listdir(CORE)):
        if f.endswith("_core.odin") and ("src/" + f[: -len("_core.odin")] + ".odin") in old_src_files:
            parts["src/" + f[: -len("_core.odin")] + ".odin"] = "src/core/" + f
    if os.path.exists(STATE_VIEW):
        parts["src/state.odin"] = rel(STATE_VIEW)
    out = []
    for line in text.split("\n"):
        cols = line.split("|")
        if line.startswith("#") or len(cols) <= 4:
            out.append(line)
            continue
        toks = cols[4].split()
        add = []
        for tok in toks:
            for old, new in parts.items():
                if fnmatch.fnmatchcase(old, tok.replace("src/core/", "src/", 1)) and new not in toks + add \
                        and not any(fnmatch.fnmatchcase(new, x) for x in toks + add):
                    add.append(new)
        if add:
            lead = cols[4][: len(cols[4]) - len(cols[4].lstrip())]
            trail = cols[4][len(cols[4].rstrip()):]
            cols[4] = lead + " ".join(toks + add) + trail
        out.append("|".join(cols))
    return "\n".join(out)


def scenes_globs(text, old_paths, new_paths, old_src_files):
    """tests/scenes.txt: an area glob over src/ that matched moved files now names src/core/
    too (or instead, when everything it matched moved)."""
    tracked_now = set(run(["git", "ls-files", "src"]).stdout.split()) | set(new_paths)

    def fix(tok):
        if not tok.startswith("src/") or tok.startswith(("src/core/", "src/native/")) or "*" not in tok and "?" not in tok:
            return tok
        old = {f for f in old_src_files if fnmatch.fnmatchcase(f, tok)}
        went = old & old_paths
        if not went:
            return tok
        now = {f for f in tracked_now if fnmatch.fnmatchcase(f, tok)}
        if {p.replace("src/", "src/core/", 1) for p in went} <= now:
            return tok  # "*" crosses "/": it still matches them
        core_tok = "src/core/" + tok[4:]
        return core_tok if went == old else tok + " " + core_tok

    out = []
    for line in text.split("\n"):
        if line.startswith("#") or "|" not in line:
            out.append(line)
            continue
        cols = line.split("|")
        ai = 4  # scene | tier | tags | secs | areas | command (and "@name | | | | globs")
        if len(cols) > ai:
            toks = cols[ai].split()
            new = " ".join(fix(t) for t in toks)
            if toks and new != " ".join(toks):
                lead = cols[ai][: len(cols[ai]) - len(cols[ai].lstrip())]
                trail = cols[ai][len(cols[ai].rstrip()):]
                cols[ai] = lead + new + trail
        out.append("|".join(cols))
    return "\n".join(out)


# --- step 6 ---------------------------------------------------------------------------------

def final_check():
    bad = []
    for pkg in ("src", "src/core"):
        for cfg, f, off, msg in errors_all(pkg, BUILDING):
            bad.append(f"{' '.join(cfg) or '(default)'} {pkg}: {line_of(f, off)}: {msg}")
    p = run(["sh", "scripts/check-core-boundary.sh"], check=False)  # noqa
    if p.returncode != 0:
        bad.append(p.stdout + p.stderr)
    new = [x for x in check_map_problems() if x not in CHECK_MAP_BEFORE]
    if new:
        bad.append("tests/scenes.py --check-map (new problems):\n" + "\n".join(new))
    return bad


CHECK_MAP_BEFORE = set()


def check_map_problems(moved=None):
    """tests/scenes.py --check-map's problems, with moved paths as they were before the move
    (so the ones the base already has are known)."""
    p = run(["python3", "-B", "tests/scenes.py", "--check-map"], check=False)
    out = []
    for ln in p.stdout.splitlines():
        if ln.startswith("check-map:"):
            continue
        out.append(re.sub(r"src/core/(\w+\.odin)", r"src/\1", ln))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-hand", action="store_true", help="stop before the hand edits (core-move-hand.patch)")
    ap.add_argument("--keep-going", action="store_true", help="a trial run: go on past blockers")
    ap.add_argument("--list", help="another classification file (a trial of a smaller core)")
    a = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)
    if a.list:
        global CORE_LIST
        CORE_LIST = os.path.abspath(a.list)
    os.chdir(ROOT)
    BUILDING[:] = build_configs() + [TEST_BUILD]
    CONFIGS[:] = BUILDING + LINUX
    print("core-move: configurations: " + ", ".join(" ".join(c) or "(default)" for c in CONFIGS), flush=True)
    if os.path.exists(CORE):
        sys.exit("core-move: src/core/ exists already: run it on the tree before the move")
    if run(["git", "status", "--porcelain", "--", "src", "tests", "docs"]).stdout.strip():
        sys.exit("core-move: src/, tests/ or docs/ has uncommitted changes: commit or stash them first")
    if not os.path.exists("build/clay-odin/clay.odin"):
        sys.exit("core-move: build/clay-odin is missing: run ./build.sh once first")
    old_src_files = set(run(["git", "ls-files", "src"]).stdout.split())
    CHECK_MAP_BEFORE.update(check_map_problems())
    all_stems = {os.path.basename(f)[:-5] for f in window_files() if not f.endswith("_test.odin")}
    moved = step_move_files()
    mover = Mover()
    step_pull(mover, a.keep_going)
    tests = step_tests(moved, all_stems, a.keep_going)
    leftovers = step_prefix()
    step_paths({**moved, **tests}, old_src_files)
    run(["git", "add", "-u"])
    run(["git", "add", "-A", "src"])
    if leftovers:
        print(f"core-move: {len(leftovers)} errors in window files the move did not fix (hand edits):")
        for f, off, msg in leftovers[:60]:
            print(f"  {line_of(f, off)}: {msg}")
    if a.no_hand or a.keep_going:
        print("core-move: done (without the hand edits)")
        return
    if os.path.exists(HAND_PATCH) and os.path.getsize(HAND_PATCH):
        p = run(["git", "apply", "--3way", "--index", HAND_PATCH], check=False)
        if p.returncode != 0:
            sys.exit(f"core-move: the hand edits did not apply (resolve them, then refresh {rel(HAND_PATCH)}):\n{p.stderr}")
        print(f"core-move: hand edits applied ({rel(HAND_PATCH)})")
    bad = final_check()
    if bad:
        print("core-move: does not build:")
        print("\n".join(bad[:80]))
        sys.exit(1)
    print("core-move: done; everything builds. Check it: scripts/core-move-verify.py")


if __name__ == "__main__":
    main()
