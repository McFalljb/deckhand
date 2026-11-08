#!/usr/bin/env python3
"""Runs test-mode scenes (tests/scripts/*.sh) in parallel: docs/TESTING.md.

Which scenes (tests/scenes.txt lists them, with their areas, tags and typical times):
  NAME...           those scenes
  --all             every required and full scene (not the manual tools, never a paid one)
  --required        the required ones (what CI runs on every pull request)
  --changed [BASE]  the scenes whose areas hold a file changed since BASE (default: main's merge
                    base), committed or not, plus the smoke scenes. An @core file (main.odin,
                    commands.odin...) adds the required scenes and the scenes whose area names
                    its changed lines mention (browser_..., claude_...); a large @core change
                    (over CORE_MAX_LINES lines) or an @all file (the build, the script engine,
                    this runner) runs everything
  --area PATH       the scenes whose areas cover PATH (a file, or a folder prefix such as src/native)
  --shard I/N       of those, shard I of N (balanced by the typical times)
  --ci              leave out the scenes tagged noci

It builds once (./build.sh and ./build.sh fake-app; skipped when both are newer than every file
they are built from; --build to build anyway, --no-build to skip: each scene still refuses a stale
build/deckhand), runs -j scenes at a time (scenes that share a lock tag one at a time,
--cef-jobs Chromium scenes at a time), retries a failed scene once and reports it as FLAKY if
the retry passes, then prints a table: result, time, log. Each scene stops at its first failed
check or wait (PI_DESK_SCRIPT_FAIL_FAST=1; --no-fail-fast to run every line) and is killed after
its timeout (3x its typical time, at least 120 s; --timeout to set one for all); a failed or
killed scene says which script line it was on (build/scenes/<scene>.step). Logs: build/scenes/<scene>.log (the
first, failed attempt of a retried scene: <scene>.1.log). Exit status 1 if a scene failed both
times; flaky scenes do not fail the run (--strict: they do).

Never starts a real pi or claude: every scene uses fakes, and paid scenes are refused.
Other commands: --list (the scenes and why they would run), --check-map (every source file is in
some scene's areas, in @all or in @unit; every area glob matches a file).
"""
import argparse
import fnmatch
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "tests", "scenes.txt")
LOGS = os.path.join(ROOT, "build", "scenes")
TIMES = os.path.join(ROOT, "build", "scene-times.json")
LOCKS = ("test-data", "test-trash")
TAGS = {"smoke", "cef", "alone", "noci", "idle"} | set(LOCKS)
TIERS = ("required", "full", "manual", "paid")
GHA = os.environ.get("GITHUB_ACTIONS") == "true"
IDLE_JOBS = 2  # idle scenes at a time, beside the -j others
# The memory budget (total RSS of the runner's process group, as a memory guard counts it): what a
# scene grows to (a busy Chromium scene 0.6-1.1 GB, an idle one ~0.6, any other ~0.17), and for
# how long after its start it may still be growing (counted at that size meanwhile)
MEM_NEED = {"cef": 1.0 * 2**30, "idle": 0.6 * 2**30, "other": 0.2 * 2**30}
MEM_YOUNG = 20.0
# a scene is killed after max(TIMEOUT_MIN, TIMEOUT_X * its typical time) (--timeout: one for all)
# (SCENE_TIMEOUT_X: CI's slower runners use more)
TIMEOUT_X, TIMEOUT_MIN = float(os.environ.get("SCENE_TIMEOUT_X", "3")), 120
# an @core change of more lines than this runs everything (a refactor, not an edit)
CORE_MAX_LINES = 300


class Scene:
    def __init__(self, name, tier, tags, secs, areas, command):
        self.name, self.tier, self.tags, self.secs, self.areas = name, tier, tags, secs, areas
        self.command = command or f"tests/scripts/{name}.sh"
        self.why = ""

    def covers(self, path):
        return any(fnmatch.fnmatchcase(path, a) for a in self.areas)


def load():
    scenes, special = [], {}
    for n, line in enumerate(open(DATA, encoding="utf-8"), 1):
        line = line.split("#", 1)[0] if line.lstrip().startswith("#") else line
        if not line.strip():
            continue
        cols = [c.strip() for c in line.rstrip("\n").split("|")]
        cols += [""] * (6 - len(cols))
        name, tier, tags, secs, areas, command = cols[:6]
        if name.startswith("@"):
            special[name] = areas.split()
            continue
        if tier not in TIERS:
            sys.exit(f"scenes.txt:{n}: {name}: tier {tier!r} is not one of {', '.join(TIERS)}")
        tagset = {t for t in tags.replace(",", " ").split()}
        if tagset - TAGS:
            sys.exit(f"scenes.txt:{n}: {name}: unknown tags {', '.join(sorted(tagset - TAGS))}")
        scenes.append(Scene(name, tier, tagset, float(secs or 30), areas.split(), command))
    names = [s.name for s in scenes]
    dup = {x for x in names if names.count(x) > 1}
    if dup:
        sys.exit(f"scenes.txt: listed twice: {', '.join(sorted(dup))}")
    return scenes, special


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def changed_files(base):
    if not base:
        for ref in ("origin/main", "main"):
            try:
                base = git("merge-base", "HEAD", ref).strip()
                break
            except subprocess.CalledProcessError:
                continue
        else:
            sys.exit("scenes: no main or origin/main to compare with: give --changed BASE")
    files = set(git("diff", "--name-only", base).split())  # committed since base, and uncommitted
    files |= set(git("ls-files", "--others", "--exclude-standard").split())
    return base, sorted(files)


CASE_RE = re.compile(r"^\s*case\s+([^:]+):")
PROC_RE = re.compile(r"^\s*(\w+)\s*::\s*(?:proc|struct|enum|union)\b")


def enclosing_names(lines, lineno):
    """The case labels and the proc (or type) around line lineno (1-based) of a file's lines,
    lower-case: an edit in a command's body names its command (case Worktree_Remove:)."""
    names, case_seen = [], False
    for ln in reversed(lines[:max(0, lineno)]):
        m = CASE_RE.match(ln)
        if m and not case_seen:
            names += [w.strip().lower() for w in m.group(1).split(",") if w.strip()]
            case_seen = True
            continue
        m = PROC_RE.match(ln)
        if m:
            names.append(m.group(1).lower())
            break
    return names


def core_changes(base, files):
    """The changed lines (added or removed, lower-case) of these files since base, with the names of
    the cases and procs they are in, and the number of changed lines."""
    out, n = [], 0
    for f in files:
        try:
            diff = git("diff", "-U0", base, "--", f)
        except subprocess.CalledProcessError:
            diff = ""
        path = os.path.join(ROOT, f)
        try:
            lines = open(path, errors="replace").read().split("\n")
        except OSError:
            lines = []
        if not diff.strip() and lines:  # untracked: all of it
            diff = "\n".join("+" + ln for ln in lines)
        for ln in diff.splitlines():
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", ln)
            if m:
                out += enclosing_names(lines, int(m.group(1)))
            elif ln[:1] in "+-" and not ln.startswith(("+++", "---")):
                out.append(ln[1:].lower())
                n += 1
    return "\n".join(out), n


def core_pick(s, text):
    """The first of s's area names that text mentions, or None."""
    return next((m for m in area_stems(s) if mentions(text, m)), None)


def area_stems(s):
    """What a scene's src/ areas are called in code: src/browser*.odin -> browser, src/app_tab.odin
    -> app_tab; generic ones (ui_*, short names) left out."""
    stems = []
    for g in s.areas:
        if not g.startswith("src/") or g.startswith("src/native/"):
            continue
        b = os.path.basename(g).split(".")[0].rstrip("*_")
        if b.startswith("ui_"):
            b = b[3:]
        if len(b) >= 4 and "*" not in b and b not in stems:
            stems.append(b)
    return stems


def mentions(text, stem):
    """stem starts an identifier or a word of text (claude in new_claude_session, Claude_Wait),
    singular or plural (worktree_remove for worktrees)."""
    forms = {stem, stem[:-1]} if stem.endswith("s") and len(stem) > 4 else {stem}
    return any(re.search(r"(?<![a-z0-9])" + re.escape(f), text) for f in forms)


def select(a, scenes, special):
    by_name = {s.name: s for s in scenes}
    for s in scenes:
        s.why = ""
    if a.names:
        out = []
        for n in a.names:
            s = by_name.get(n)
            if not s:
                sys.exit(f"scenes: no scene {n!r} in tests/scenes.txt (--list shows them)")
            s.why = "named"
            out.append(s)
    elif a.changed is not None or a.area:
        if a.area:
            files, label = list(a.area), "area " + " ".join(a.area)
        else:
            base, files = changed_files(a.changed or None)
            label = f"changed since {base[:12]}"
        everything = [f for f in files if any(fnmatch.fnmatchcase(f, g) for g in special.get("@all", []))]
        core = [f for f in files if f not in everything and any(fnmatch.fnmatchcase(f, g) for g in special.get("@core", []))]
        core_why = {}  # scene name -> why an @core change selects it
        if core and not everything:
            if a.area:
                everything = [core[0]]
            else:
                text, n = core_changes(base, core)
                if n > CORE_MAX_LINES:
                    everything = [f"{core[0]} ({n} lines changed in core files)"]
                else:
                    for s in scenes:
                        if s.tier == "required":
                            core_why[s.name] = f"{core[0]} (required)"
                        else:
                            stem = core_pick(s, text)
                            if stem:
                                core_why[s.name] = f"{core[0]} mentions {stem}"
        out = []
        for s in scenes:
            if s.tier not in ("required", "full"):
                continue
            hits = [f for f in files if s.covers(f) or any(g.startswith(f.rstrip("/") + "/") for g in s.areas)]
            if everything:
                s.why = f"{everything[0]} (every scene)"
            elif hits:
                s.why = hits[0] + (f" +{len(hits) - 1}" if len(hits) > 1 else "")
            elif s.name in core_why:
                s.why = core_why[s.name]
            elif "smoke" in s.tags and not a.area:
                s.why = "smoke"
            if s.why:
                out.append(s)
        unmapped = [f for f in files if f.startswith(("src/", "tests/scripts/", "integrations/", "tools/"))
                    and not any(s.covers(f) or any(g.startswith(f.rstrip("/") + "/") for g in s.areas) for s in scenes)
                    and not any(fnmatch.fnmatchcase(f, g) for g in special.get("@all", []) + special.get("@core", []) + special.get("@unit", []))]
        print(f"scenes: {label}: {len(files)} files", file=sys.stderr)
        if unmapped:
            print("scenes: no scene covers: " + " ".join(unmapped) + " (add it to tests/scenes.txt)", file=sys.stderr)
    else:
        tiers = ("required",) if a.required else ("required", "full")
        out = [s for s in scenes if s.tier in tiers]
        for s in out:
            s.why = s.tier
    if a.ci:
        out = [s for s in out if "noci" not in s.tags]
    paid = [s.name for s in out if s.tier == "paid"]
    if paid:
        sys.exit(f"scenes: {', '.join(paid)} start a real pi on paid models: never from this runner "
                 "(docs/DEVELOPING.md, \"Test mode and scenes\")")
    if a.shard:
        i, n = (int(x) for x in a.shard.split("/"))
        if not 1 <= i <= n:
            sys.exit("scenes: --shard I/N with 1 <= I <= N")
        bins = [[0.0, []] for _ in range(n)]
        for s in sorted(out, key=lambda s: (-s.secs, s.name)):
            b = min(bins, key=lambda b: b[0])
            b[0] += s.secs
            b[1].append(s)
        out = bins[i - 1][1]
    return out


def check_map(scenes, special):
    tracked = git("ls-files").split()
    src = [f for f in tracked if f.startswith(("src/", "integrations/", "tools/", "tests/scripts/"))
           and not f.endswith((".md",))]
    globs = special.get("@all", []) + special.get("@core", []) + special.get("@unit", [])
    bad = 0
    for f in src:
        if not (any(s.covers(f) for s in scenes) or any(fnmatch.fnmatchcase(f, g) for g in globs)):
            if f.startswith("tests/scripts/") and not f.endswith((".sh", ".txt", ".py")):
                continue
            print(f"no scene, @all, @core or @unit covers {f}")
            bad += 1
    for s in scenes:
        for g in s.areas:
            if not any(fnmatch.fnmatchcase(f, g) for f in tracked):
                print(f"{s.name}: area {g} matches no file")
                bad += 1
        cmd = s.command.split()
        script = next((c for c in cmd if c.startswith("tests/scripts/")), None)
        if script and not os.path.exists(os.path.join(ROOT, script)):
            print(f"{s.name}: {script} does not exist")
            bad += 1
    for sh in sorted(f for f in tracked if f.startswith("tests/scripts/") and f.endswith(".sh")):
        if not any(sh in s.command.split() for s in scenes) and sh not in (
                "tests/scripts/fresh-build.sh", "tests/scripts/claude-stub.sh", "tests/scripts/fake-bridge.sh",
                "tests/scripts/fake-fish.sh", "tests/scripts/fake-install.sh", "tests/scripts/text-sample.sh"):
            print(f"{sh} is not in tests/scenes.txt")
            bad += 1
    print(f"check-map: {bad} problem(s)")
    return bad == 0


def kill_tree(pid):
    """SIGKILL pid and everything below it (children first are found, then all are killed)."""
    pids, todo = [], [pid]
    while todo:
        p = todo.pop()
        pids.append(p)
        out = subprocess.run(["pgrep", "-P", str(p)], capture_output=True, text=True).stdout
        todo += [int(x) for x in out.split()]
    for p in pids:
        try:
            os.kill(p, signal.SIGKILL)
        except ProcessLookupError:
            pass


# What ./build.sh and ./build.sh fake-app build from (build.sh, bundle-app.sh, the #load-ed files;
# tests/scripts/fresh-build.sh checks most of it too): the build is skipped when every file here is
# older than the output and the list of files is the one the last build saw (a deleted or renamed
# file changes it: build/<output>.inputs)
APP_INPUTS = ["src", "tools/pi-desk-cli", "integrations/claude-code", "integrations/pi/extensions",
              "integrations/pi/lib", "integrations/pi/skills", "integrations/pi/extensions.json",
              "integrations/pi/package.json", "integrations/pi/README.md", "build.sh", "scripts/bundle-app.sh",
              "scripts/fetch-cef.sh", "scripts/check-minos.sh", "scripts/entitlements", "assets", "vendor",
              "docs/GUIDE.md", "docs/PROTOCOL.md", "tests/markdown"]
FAKE_APP_INPUTS = ["tests/fake-app", "build.sh"]
# built into vendor/sokol-odin by build.sh itself: not inputs
GENERATED = ("_metal_release.a",)


def input_files(inputs):
    """Every file under inputs (relative paths, sorted; *_test.odin left out: not in the binary)."""
    out = []
    for top in inputs:
        path = os.path.join(ROOT, top)
        if os.path.isfile(path):
            out.append(top)
            continue
        for d, dirs, fs in os.walk(path):
            dirs[:] = [x for x in dirs if x != ".git"]
            out += [os.path.relpath(os.path.join(d, f), ROOT) for f in fs
                    if not f.endswith("_test.odin") and not f.endswith(GENERATED) and f != ".DS_Store"]
    return sorted(out)


def list_file(out):
    return os.path.join(ROOT, "build", os.path.basename(out) + ".inputs")


def stale_input(out, inputs):
    """Why out needs building: the first input newer than it, a changed file list, or no out; ""
    when out is fresh."""
    try:
        built = os.stat(os.path.join(ROOT, out)).st_mtime
    except OSError:
        return f"no {out}"
    files = input_files(inputs)
    try:
        last = open(list_file(out)).read().split("\n")
    except OSError:
        last = None
    if last != files:
        return "its list of source files changed" if last is not None else "no record of its sources"
    for f in files:
        try:
            if os.stat(os.path.join(ROOT, f)).st_mtime > built:
                return f
        except OSError:
            return f
    return ""


def record_inputs(out, inputs):
    try:
        with open(list_file(out), "w") as fh:
            fh.write("\n".join(input_files(inputs)))
    except OSError:
        pass


def mem_need(s):
    if "cef" in s.tags:
        return MEM_NEED["idle" if "idle" in s.tags else "cef"]
    return MEM_NEED["other"]


def last_step(name):
    """The script line the scene was on (PI_DESK_SCRIPT_STEP: src/autotest.odin), or ""."""
    try:
        return open(os.path.join(LOGS, name + ".step"), errors="replace").read().strip()
    except OSError:
        return ""


class Runner:
    def __init__(self, scenes, jobs, cef_jobs, retries, timeout, mem_budget=0, fail_fast=True, last=None):
        self.pending = list(scenes)
        self.jobs, self.cef_jobs, self.retries, self.timeout = jobs, cef_jobs, retries, timeout
        self.fail_fast, self.last = fail_fast, last or {}
        self.mem_budget = mem_budget  # bytes; 0: no budget
        self.rss, self.started_at = 0, {}
        self.running = {}  # name -> Scene
        self.results = {}  # name -> dict
        self.cv = threading.Condition()
        self.order = []

    def can_start(self, s):
        # idle scenes (an idle period is what they test: browser-rlz, browser-netpolicy) sleep most
        # of their run: they take no -j slot (a Chromium slot still: its memory), at most IDLE_JOBS
        busy = [r for r in self.running.values() if "idle" not in r.tags]
        if "idle" in s.tags:
            if sum("idle" in r.tags for r in self.running.values()) >= IDLE_JOBS:
                return False
        elif len(busy) >= self.jobs:
            return False
        if self.running and ("alone" in s.tags or any("alone" in r.tags for r in self.running.values())):
            return False
        for lock in LOCKS:
            if lock in s.tags and any(lock in r.tags for r in self.running.values()):
                return False
        if "cef" in s.tags and sum("cef" in r.tags for r in self.running.values()) >= self.cef_jobs:
            return False
        # the memory budget: what runs now, what the scenes started lately may still grow to, and
        # what this one will take (one scene alone always starts)
        if self.mem_budget and self.running:
            now = time.monotonic()
            young = sum(mem_need(r) for r in self.running.values() if now - self.started_at.get(r.name, 0) < MEM_YOUNG)
            if self.rss + young + mem_need(s) > self.mem_budget:
                return False
        return True

    def timeout_of(self, s):
        if self.timeout:
            return self.timeout
        return max(TIMEOUT_MIN, TIMEOUT_X * max(s.secs, self.last.get(s.name, 0)))

    def attempt(self, s, log):
        t0 = time.monotonic()
        timeout = self.timeout_of(s)
        step = os.path.join(LOGS, s.name + ".step")
        try:
            os.remove(step)
        except FileNotFoundError:
            pass
        env = dict(os.environ, PI_DESK_SCRIPT_STEP=step, PI_DESK_SCRIPT_FAIL_FAST="1" if self.fail_fast else "0")
        with open(log, "w") as fh:
            fh.write(f"# {s.name}: {s.command}   (started {time.strftime('%H:%M:%S')}, load {os.getloadavg()[0]:.1f}, "
                     f"timeout {timeout:.0f} s)\n")
            fh.flush()
            # in the runner's process group: whatever stops or limits the runner (a CI timeout,
            # a memory guard) reaches the scenes too
            p = subprocess.Popen(["/bin/sh", "-c", "exec " + s.command], cwd=ROOT, stdout=fh,
                                 stderr=subprocess.STDOUT, env=env)
            try:
                rc = p.wait(timeout)
            except subprocess.TimeoutExpired:
                kill_tree(p.pid)
                p.wait()
                rc = 124
                fh.write(f"\n# scenes.py: killed after {timeout:.0f} s ("
                         f"{'--timeout' if self.timeout else f'{TIMEOUT_X:g}x its typical time, at least {TIMEOUT_MIN} s'})\n"
                         f"# last script step: {last_step(s.name) or '(none: before the app ran a script line)'}\n")
            secs = time.monotonic() - t0
            if rc != 0 and rc != 124 and last_step(s.name):
                fh.write(f"\n# last script step: {last_step(s.name)}\n")
            fh.write(f"\n# {s.name}: exit {rc} after {secs:.1f} s (load {os.getloadavg()[0]:.1f})\n")
        return rc, secs

    def run_one(self, s):
        log = os.path.join(LOGS, s.name + ".log")
        rc, secs = self.attempt(s, log)
        times = [secs]
        result = "pass" if rc == 0 else "FAIL"
        killed = rc == 124
        step = last_step(s.name) if rc != 0 else ""
        if rc != 0 and self.retries:
            os.replace(log, os.path.join(LOGS, s.name + ".1.log"))
            rc, secs2 = self.attempt(s, log)
            times.append(secs2)
            result = "FLAKY" if rc == 0 else "FAIL"
            killed = rc == 124
            step = last_step(s.name) if rc != 0 else step
        with self.cv:
            self.results[s.name] = {"result": result, "times": times, "log": os.path.relpath(log, ROOT),
                                    "killed": killed and result == "FAIL", "step": step}
            del self.running[s.name]
            done = len(self.results)
            total = done + len(self.pending) + len(self.running)
            extra = (" (2 tries)" if len(times) > 1 else "") + (" KILLED (timeout)" if killed and result == "FAIL" else "")
            if result == "FAIL" and step:
                extra += f"  at {step}"
            print(f"[{done}/{total}] {result:5} {s.name} {sum(times):.0f}s{extra}", flush=True)
            self.cv.notify_all()

    def sample_memory(self):
        """The peak total RSS of the runner's process group (every scene's processes)."""
        pg = os.getpgrp()
        while not self.finished:
            out = subprocess.run(["ps", "-axo", "pgid=,rss="], capture_output=True, text=True).stdout
            kb = sum(int(r) for g, r in (l.split() for l in out.splitlines() if l.strip()) if int(g) == pg)
            self.rss = kb * 1024
            self.peak_rss = max(self.peak_rss, self.rss)
            time.sleep(0.5)

    def run(self):
        self.finished, self.peak_rss = False, 0
        threading.Thread(target=self.sample_memory, daemon=True).start()
        try:
            self._run()
        finally:
            self.finished = True

    def _run(self):
        with self.cv:
            while self.pending or self.running:
                started = False
                for s in list(self.pending):
                    if self.can_start(s):
                        self.pending.remove(s)
                        self.running[s.name] = s
                        self.started_at[s.name] = time.monotonic()
                        self.order.append(s.name)
                        threading.Thread(target=self.run_one, args=(s,), daemon=True).start()
                        started = True
                if not started:
                    self.cv.wait(0.5 if self.mem_budget else None)  # memory goes down without a notify


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--required", action="store_true")
    ap.add_argument("--changed", nargs="?", const="", metavar="BASE")
    ap.add_argument("--area", metavar="PATH", action="append", help="repeatable")
    ap.add_argument("--shard", metavar="I/N")
    ap.add_argument("--ci", action="store_true", help="leave out noci scenes")
    ap.add_argument("-j", type=int, default=int(os.environ.get("SCENE_JOBS", "0")) or None,
                    help="scenes at a time, idle ones not counted (default: 8 with 10+ CPUs, 4 with 8+, "
                    "else 2; SCENE_JOBS)")
    ap.add_argument("--cef-jobs", type=int, default=int(os.environ.get("SCENE_CEF_JOBS", "0")) or None,
                    help="Chromium scenes at a time, idle ones counted: each holds 0.6-1.1 GB (default: 3 "
                    "with 10+ CPUs, else 1; SCENE_CEF_JOBS)")
    ap.add_argument("--mem-gb", type=float, default=float(os.environ.get("SCENE_MEM_GB", "3.5")),
                    help="start no scene that could take the run's total RSS past this (default 3.5; "
                    "SCENE_MEM_GB; 0: no budget)")
    ap.add_argument("--retries", type=int, default=1, choices=(0, 1))
    ap.add_argument("--timeout", type=int, default=0, help=f"seconds per attempt, for every scene (default: "
                    f"{TIMEOUT_X}x the scene's typical or last time, at least {TIMEOUT_MIN} s)")
    ap.add_argument("--no-fail-fast", action="store_true", help="run every script line after a failure "
                    "(PI_DESK_SCRIPT_FAIL_FAST=0): to see all of a script's failures at once")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--build", action="store_true", help="build even when build/deckhand and build/fake-app look fresh")
    ap.add_argument("--strict", action="store_true", help="a flaky scene fails the run")
    ap.add_argument("--soft-tier", choices=TIERS, help="a failed scene of this tier is a warning, "
                    "not a failure (the nightly run's not-yet-required scenes)")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--check-map", action="store_true")
    a = ap.parse_args()
    os.chdir(ROOT)
    scenes, special = load()
    if a.check_map:
        sys.exit(0 if check_map(scenes, special) else 1)
    if not (a.names or a.all or a.required or a.changed is not None or a.area):
        ap.error("name scenes, or use --all, --required, --changed or --area (--list shows them)")
    chosen = select(a, scenes, special)
    try:
        last = json.load(open(TIMES))
    except (OSError, ValueError):
        last = {}
    chosen.sort(key=lambda s: (-last.get(s.name, s.secs), s.name))  # longest first
    if a.list:
        for s in chosen:
            print(f"{s.name:20} {s.tier:9} {','.join(sorted(s.tags)) or '-':22} {s.secs:5.0f}s  {s.why}")
        print(f"{len(chosen)} scenes, {sum(s.secs for s in chosen) / 60:.1f} min serial")
        return
    if not chosen:
        print("scenes: nothing to run")
        return
    cpus = os.cpu_count() or 2
    jobs = a.j or (8 if cpus >= 10 else 4 if cpus >= 8 else 2)
    a.cef_jobs = a.cef_jobs or (3 if cpus >= 10 else 1)
    if not a.no_build:
        b0 = time.monotonic()
        builds = (("./build.sh", "build/deckhand", APP_INPUTS), ("./build.sh fake-app", "build/fake-app", FAKE_APP_INPUTS))
        stale = [(cmd, out, ins, why) for cmd, out, ins in builds for why in [stale_input(out, ins)] if why or a.build]
        for cmd, out, ins, why in stale:
            files_before = input_files(ins)
            if subprocess.run(cmd.split(), stdout=subprocess.DEVNULL if not GHA else None).returncode != 0:
                sys.exit(f"scenes: {cmd} failed")
            if input_files(ins) == files_before:  # nothing came or went during the build
                record_inputs(out, ins)
        stale = [(cmd, why) for cmd, _, _, why in stale]
        if stale:
            print(f"scenes: built in {time.monotonic() - b0:.0f} s ({'; '.join(c + ': ' + (w or '--build') for c, w in stale)})")
        else:
            print("scenes: build/deckhand and build/fake-app are newer than their sources: not rebuilt (--build to)")
    os.makedirs(LOGS, exist_ok=True)
    for s in chosen:
        for f in (s.name + ".log", s.name + ".1.log"):
            try:
                os.remove(os.path.join(LOGS, f))
            except FileNotFoundError:
                pass
    load0 = os.getloadavg()[0]
    print(f"scenes: {len(chosen)} scenes, {jobs} at a time (Chromium: {a.cef_jobs}; memory budget "
          f"{a.mem_gb:g} GB), load {load0:.1f}", flush=True)
    t0 = time.monotonic()
    r = Runner(chosen, jobs, a.cef_jobs, a.retries, a.timeout, int(a.mem_gb * 2**30), not a.no_fail_fast, last)
    r.run()
    wall = time.monotonic() - t0

    times = dict(last)
    for name, res in r.results.items():
        if res["result"] == "pass":
            times[name] = round(res["times"][0], 1)
    try:
        json.dump(times, open(TIMES, "w"), indent=0, sort_keys=True)
    except OSError:
        pass
    rows = [f"{'scene':20} {'result':6} {'secs':>6}  log"]
    for name in r.order:
        res = r.results[name]
        t = " + ".join(f"{x:.0f}" for x in res["times"])
        rows.append(f"{name:20} {res['result']:6} {t:>6}  {res['log']}")
        if res["result"] == "FAIL":
            rows.append(f"{'':20} {'killed after its timeout' if res['killed'] else 'failed'}; last script step: "
                        f"{res['step'] or '(none recorded)'}")
    tier_of = {s.name: s.tier for s in chosen}
    failed = [n for n in r.order if r.results[n]["result"] == "FAIL"]
    soft = [n for n in failed if tier_of[n] == a.soft_tier]
    hard = [n for n in failed if n not in soft]
    flaky = [n for n in r.order if r.results[n]["result"] == "FLAKY"]
    serial = sum(sum(x["times"]) for x in r.results.values())
    rows.append(f"{len(r.order)} scenes in {wall / 60:.1f} min ({serial / 60:.1f} min of scene time, {jobs} at a time; "
                f"load {load0:.1f} -> {os.getloadavg()[0]:.1f}; peak memory {r.peak_rss / 2**30:.1f} GB)")
    if flaky:
        rows.append("FLAKY (failed, then passed on the retry; first log: <scene>.1.log): " + " ".join(flaky))
    if hard:
        rows.append("FAILED: " + " ".join(hard))
    if soft:
        rows.append(f"FAILED ({a.soft_tier}, not failing the run): " + " ".join(soft))
    text = "\n".join(rows)
    print("\n" + text)
    with open(os.path.join(LOGS, "summary.txt"), "w") as fh:
        fh.write(text + "\n")
    for n in failed:
        log = os.path.join(ROOT, r.results[n]["log"])
        tail = open(log, errors="replace").read().splitlines()[-30:]
        if GHA:
            kind = "warning" if n in soft else "error"
            print(f"::{kind}::scene {n} failed ({r.results[n]['log']})")
            print(f"::group::{n} (last 30 lines)")
        else:
            print(f"\n--- {n}: last 30 lines of {r.results[n]['log']}")
        print("\n".join(tail))
        if GHA:
            print("::endgroup::")
    if GHA:
        for n in flaky:
            print(f"::warning::scene {n} is flaky: failed, then passed ({r.results[n]['log'][:-4]}.1.log)")
    if hard or (a.strict and flaky):
        sys.exit(1)


if __name__ == "__main__":
    main()
