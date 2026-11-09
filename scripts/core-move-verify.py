#!/usr/bin/env python3
"""Checks M2-B's move (scripts/core-move.py, docs/plans/background-core.md §10.2): take back
out everything the script does by rule, and what is left must be the hand edits.

Both trees (BASE, before the move, and HEAD, after it) are normalised the same way:
  - a moved file is compared at its old path (src/core/x.odin with src/x.odin), as package main,
    with its relative imports, foreign imports and #load paths resolved to the files they name;
  - in Odin code (not comments or strings): every `core.` prefix, every `import "core"` line,
    `state^` and the bare `&state` (the window's `state: ^core.State`) are taken out;
  - everywhere else in the repository, paths of moved files read as before (src/core/x.odin ->
    src/x.odin), and tests/scenes.txt's area globs too;
  - each declaration in src/core/<stem>_core.odin must be, word for word, one that BASE's
    src/<stem>.odin has: it is cut from there (as the script cuts it) and the rest of that
    window file is compared;
  - src/state_view.odin must be the script's (STATE_VIEW_TEXT).
Then HEAD minus scripts/core-move-hand.patch (reversed, in a temporary copy) must equal BASE,
apart from @(private) dropped from core declarations the window uses (listed). Anything else is
printed as a diff and the check fails.

Usage: scripts/core-move-verify.py [--base COMMIT] [--head COMMIT | --worktree]
  --base      the tree before the move (default: the newest first-parent ancestor of HEAD
              without src/core/)
  --head      the tree after it (default HEAD); --worktree: the files on disk
"""
import argparse
import collections
import difflib
import importlib.util
import os
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import odin_src as osrc  # noqa: E402

_spec = importlib.util.spec_from_file_location("core_move", os.path.join(HERE, "core-move.py"))
cm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cm)

SKIP = ("vendor/", "build/")


def git(*args, inp=None):
    p = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, input=inp)
    if p.returncode != 0:
        sys.exit(f"core-move-verify: git {' '.join(args)}: {p.stderr.decode(errors='replace')}")
    return p.stdout


def tree(commit):
    """path -> text for the commit's text files (vendor/ aside)."""
    if commit is None:
        paths = git("ls-files", "-co", "--exclude-standard").decode().split("\n")
        out = {}
        for p in paths:
            if p and not p.startswith(SKIP) and os.path.isfile(os.path.join(ROOT, p)):
                try:
                    out[p] = open(os.path.join(ROOT, p), encoding="utf-8", newline="").read()
                except (UnicodeDecodeError, OSError):
                    pass
        return out
    lines = git("ls-tree", "-r", commit).decode().split("\n")
    objs = []
    for ln in lines:
        if not ln:
            continue
        meta, path = ln.split("\t", 1)
        mode, kind, sha = meta.split()
        if kind == "blob" and not path.startswith(SKIP):
            objs.append((path, sha))
    data = git("cat-file", "--batch", inp="\n".join(s for _, s in objs).encode() + b"\n")
    out, at = {}, 0
    for path, sha in objs:
        nl = data.index(b"\n", at)
        size = int(data[at:nl].split()[2])
        body = data[nl + 1:nl + 1 + size]
        at = nl + 1 + size + 1
        try:
            out[path] = body.decode("utf-8")
        except UnicodeDecodeError:
            pass
    return out


def default_base(head):
    for c in git("rev-list", "--first-parent", head or "HEAD").decode().split():
        if not git("ls-tree", c, "src/core/").strip():
            return c
    sys.exit("core-move-verify: no ancestor without src/core/: pass --base")


def unhand(head):
    """HEAD with the hand patch reversed (the patch from HEAD's own tree); (tree, patch text)."""
    patch = head.get("scripts/core-move-hand.patch", "")
    if not patch.strip():
        return head, ""
    touched = set(re.findall(r"(?m)^diff --git a/(\S+) b/(\S+)", patch))
    paths = {p for pair in touched for p in pair}
    with tempfile.TemporaryDirectory() as d:
        for p in paths:
            if p in head:
                os.makedirs(os.path.dirname(os.path.join(d, p)) or d, exist_ok=True)
                with open(os.path.join(d, p), "w", encoding="utf-8") as fh:
                    fh.write(head[p])
        pf = os.path.join(d, ".hand.patch")
        with open(pf, "w", encoding="utf-8") as fh:
            fh.write(patch)
        p = subprocess.run(["git", "apply", "-R", "--unsafe-paths", ".hand.patch"], cwd=d, capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit(f"core-move-verify: scripts/core-move-hand.patch does not reverse out of HEAD:\n{p.stderr}")
        out = dict(head)
        for path in paths:
            fp = os.path.join(d, path)
            if os.path.exists(fp):
                out[path] = open(fp, encoding="utf-8").read()
            else:
                out.pop(path, None)
    return out, patch


# --- normalisation -----------------------------------------------------------------------------

def strip_code(text, counts):
    """Takes out the move's rules in Odin code: `core.`, `import "core"`, `state^`, bare
    `&state`, `package core`."""
    text = re.sub(r"(?m)^package core\b", "package main", text, count=1)
    # the script's import: alone after the package line (with a blank line before it), or among
    # the others
    text = re.sub(r'(?m)^(package \w+[^\n]*\n)\nimport[ \t]+"core"[ \t]*\n', r"\1", text, count=1)
    text, k = re.subn(r'(?m)^import[ \t]+"core"[ \t]*\n', "", text)
    mask = osrc.code_mask(text)
    out, i, n = [], 0, len(text)
    def starts_name(i):
        # not part of a name or a selector (`x.core.y`); `..core.T` (variadic) is fine
        if i == 0:
            return True
        if re.match(r"\w", text[i - 1]):
            return False
        return text[i - 1] != "." or (i >= 2 and text[i - 2] == ".")

    while i < n:
        if mask[i] and starts_name(i):
            if text.startswith("core.", i) and i + 5 < n and re.match(r"[A-Za-z_]", text[i + 5]):
                counts["prefix"] += 1
                i += 5
                continue
            if text.startswith("state^", i) and (i + 6 >= n or not re.match(r"[\w.]", text[i + 6])):
                counts["deref"] += 1
                out.append("state")
                i += 6
                continue
            if text.startswith("&state", i) and (i + 6 >= n or not re.match(r"[\w.\[]", text[i + 6])):
                counts["addr"] += 1
                out.append("state")
                i += 6
                continue
        out.append(text[i])
        i += 1
    return "".join(out)


def canon_paths(text, file_dir, moved_back):
    """Relative paths in imports, foreign imports and #load resolved to repository paths (as
    BASE would name them): `"@src/ghostty"`."""

    def fix(path):
        if ":" in path.split("/")[0] or path.startswith("/"):
            return path
        target = os.path.normpath(os.path.join(file_dir, path))
        target = moved_back.get(target, target)
        return "@" + target

    text = re.sub(r'(?m)^(import[ \t]+(?:[A-Za-z_]\w*[ \t]+)?)"([^"]+)"', lambda m: m.group(1) + '"' + fix(m.group(2)) + '"', text)
    text = re.sub(r'(?m)^([ \t]*foreign[ \t]+import[ \t]+\w+[ \t]*)(\{[^}]*\}|"[^"]*")',
                  lambda m: m.group(1) + re.sub(r'"([^"]+)"', lambda q: '"' + fix(q.group(1)) + '"', m.group(2)), text)
    text = re.sub(r'#load\("([^"]+)"', lambda m: '#load("' + fix(m.group(1)) + '"', text)
    return text


def path_back(text, moved_back, counts):
    if not moved_back:
        return text
    pat = re.compile(r"(?<![\w.\-])(" + "|".join(re.escape(n) for n in sorted(moved_back, key=len, reverse=True)) + r")(?![\w])")
    text, k = pat.subn(lambda m: moved_back[m.group(1)], text)
    counts["paths"] += k
    return text


def path_back_only(text, moved_back, drop):
    """path_back for tests/scenes.txt, leaving the dropped tokens as they are."""
    out = []
    for tok in re.split(r"(\s+)", text):
        out.append(tok if tok in drop else path_back(tok, moved_back, collections.Counter()))
    return "".join(out)


def scenes_back(text, drop=()):
    out = []
    for line in text.split("\n"):
        if line.startswith("#") or "|" not in line:
            out.append(line)
            continue
        cols = line.split("|")
        if len(cols) > 4:
            seen, toks = set(), []
            for t in cols[4].split():
                if t in drop:
                    continue  # a file the move made, named beside its source (scenes_parts)
                t = t.replace("src/core/", "src/", 1) if t.startswith("src/core/") else t
                if t not in seen:
                    seen.add(t)
                    toks.append(t)
            lead = cols[4][: len(cols[4]) - len(cols[4].lstrip())]
            trail = cols[4][len(cols[4].rstrip()):]
            cols[4] = lead + " ".join(toks) + trail if toks else cols[4]
        out.append("|".join(cols))
    return "\n".join(out)


def normalise(path, text, at_dir, moved_back, counts, drop=()):
    if path == "tests/scenes.txt":
        text = scenes_back(path_back_only(text, moved_back, drop), drop)
        return text
    text = path_back(text, moved_back, counts)
    if path.endswith(".odin") and path.startswith("src/"):
        text = strip_code(text, counts)
        text = canon_paths(text, at_dir, moved_back)
    return text


# --- the check -------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base")
    ap.add_argument("--head")
    ap.add_argument("--worktree", action="store_true")
    a = ap.parse_args()
    head_ref = None if a.worktree else (a.head or "HEAD")
    base_ref = a.base or default_base(head_ref)
    base = tree(base_ref)
    head_full = tree(head_ref)
    head, patch = unhand(head_full)
    problems = []

    # what moved: src/core/x.odin whose src/x.odin was in BASE (and is gone from HEAD)
    moved_back = {}
    for p in head:
        if p.startswith("src/core/") and p.count("/") == 2:
            old = "src/" + p[len("src/core/"):]
            if old in base and old not in head:
                moved_back[p] = old
    parts = {p: "src/" + p[len("src/core/"):-len("_core.odin")] + ".odin"
             for p in head if p.startswith("src/core/") and p.endswith("_core.odin") and p not in moved_back}
    sources = sorted(p for p in moved_back if not p.endswith("_test.odin"))
    tests = sorted(p for p in moved_back if p.endswith("_test.odin"))

    counts = collections.Counter()
    drop = set(parts) | {"src/state_view.odin"}
    nb = {}
    base_counts = collections.Counter()
    for p, t in base.items():
        if p == "scripts/core-move-hand.patch":
            continue
        nb[p] = normalise(p, t, os.path.dirname(p), moved_back, base_counts)
    nh = {}
    for p, t in head.items():
        if p in parts or p in ("src/state_view.odin", "scripts/core-move-hand.patch"):
            continue
        q = moved_back.get(p, p)
        nh[q] = normalise(p, t, os.path.dirname(p), moved_back, counts, drop)

    # moved blocks
    blocks = {}
    for p, wf in sorted(parts.items()):
        if wf not in nb:
            problems.append(f"{p}: no {wf} in BASE")
            continue
        ht = normalise(p, head[p], "src/core", moved_back, collections.Counter())
        bdecls = {d.name: d for d in osrc.top_decls(nb[wf])}
        spans, names = [], []
        hdecls = osrc.top_decls(ht)
        rest = ht
        for d in hdecls:
            bd = bdecls.get(d.name)
            htxt = ht[d.head_start:d.end].rstrip("\n")
            if not bd or nb[wf][bd.head_start:bd.end].rstrip("\n") != htxt:
                problems.append(f"{p}: {d.name} is not, word for word, a declaration of BASE's {wf}")
                continue
            if (bd.head_start, bd.end) not in spans:
                spans.append((bd.head_start, bd.end))
                names.append(d.name)
            rest = rest.replace(htxt, "", 1)
        # what is left of the core part: its package line, header comment and imports only
        for ln in rest.split("\n"):
            s = ln.strip()
            if s and not (s.startswith(("package ", "//", "import ")) or s == ""):
                problems.append(f"{p}: a line that is no moved declaration: {ln!r}")
        nb[wf], _ = cm.cut_blocks(nb[wf], spans)
        blocks[wf] = names

    if "src/state_view.odin" in head and head["src/state_view.odin"] != cm.STATE_VIEW_TEXT:
        problems.append("src/state_view.odin is not the script's (core-move.py STATE_VIEW_TEXT)")

    # the comparison
    privates, diffs = [], []
    for p in sorted(set(nb) | set(nh)):
        b, h = nb.get(p), nh.get(p)
        if b == h:
            continue
        if b is None or h is None:
            diffs.append(f"--- {p}: {'only in HEAD' if b is None else 'missing from HEAD'}")
            continue
        bl, hl = b.split("\n"), h.split("\n")
        sm = difflib.SequenceMatcher(None, bl, hl, autojunk=False)
        rest = []
        for op, i1, i2, j1, j2 in sm.get_opcodes():
            if op == "equal":
                continue
            old, new = bl[i1:i2], hl[j1:j2]
            if op == "delete" and all(x.strip() == "@(private)" for x in old):
                privates.append(f"{p}:{i1 + 1}")
                continue
            if op == "replace" and len(old) == len(new) and all(o.replace("@(private) ", "", 1) == n for o, n in zip(old, new)):
                privates.append(f"{p}:{i1 + 1}")
                continue
            rest.append((i1, i2, j1, j2))
        if rest:
            d = difflib.unified_diff(bl, hl, f"BASE/{p}", f"HEAD/{p}", n=2, lineterm="")
            diffs.append("\n".join(list(d)[:200]))

    inits = []
    for p, t in sorted(head.items()):
        if p.startswith("src/") and p.endswith(".odin") and not p.endswith("_test.odin"):
            for m in re.finditer(r"(?m)^@\(init\)\s*\n?\s*(\w+)", t):
                inits.append(f"{p}: {m.group(1)}")

    print(f"core-move-verify: BASE {base_ref[:12]}  HEAD {head_ref or 'worktree'}")
    print(f"  moved: {len(sources)} source files and {len(tests)} test files into src/core/")
    print(f"  declarations moved from window files: {sum(len(v) for v in blocks.values())}"
          f" ({len(blocks)} files)")
    for wf, names in blocks.items():
        print(f"    {wf}: {' '.join(names)}")
    counts.subtract(base_counts)  # what the move added, not what was there before
    print(f"  by rule: {counts['prefix']} `core.` prefixes, {counts['deref']} `state^`, {counts['addr']} "
          f"`&state`, {counts['paths']} paths of moved files")
    print(f"  @(private) dropped (the window uses them): {len(privates)} {' '.join(privates)}")
    print(f"  @(init) procs (the core's now run before the window's): {'; '.join(inits) or 'none'}")
    if patch:
        hunks = re.findall(r"(?m)^diff --git a/(\S+)", patch)
        plus = len(re.findall(r"(?m)^\+(?!\+\+)", patch))
        minus = len(re.findall(r"(?m)^-(?!--)", patch))
        print(f"  hand edits (scripts/core-move-hand.patch): {len(hunks)} files, +{plus} -{minus}: {' '.join(hunks)}")
    else:
        print("  hand edits: none (no scripts/core-move-hand.patch)")
    if problems or diffs:
        print(f"core-move-verify: FAILED: {len(problems)} problems, {len(diffs)} files differ beyond the rules:")
        for x in problems:
            print("  " + x)
        for d in diffs:
            print(d)
        sys.exit(1)
    print("core-move-verify: ok: the remainder is the hand edits")


if __name__ == "__main__":
    main()
