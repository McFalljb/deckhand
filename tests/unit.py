#!/usr/bin/env python3
"""The command-layer tests (src/*_test.odin) in parallel processes.

The tests share the global State, so each process runs one thread; the speed comes from running
several processes at once, each with its own TMPDIR (temp folders, the control socket's runtime
dir). One test binary is built, then every src/*.odin file's tests run as one chunk; chunks go to
-j workers, the slowest first (build/unit-times.json, from the last run). The timing tests
(TIMING below) run after the rest, one at a time, so the other chunks' load does not skew them.

The perf layer: a time budget (perf_expect, src/cpu_clock_test.odin) never fails this run unless
it is 10x over (an accidentally quadratic change); over the budget it is a warning in the summary
("perf: over budget"), so a busy machine cannot fail a gate. --perf-strict
(DECKHAND_PERF_STRICT=1, for a quiet machine) fails at the budget itself.

Fails if a test fails, or if the number of tests that ran is not the number of @(test) procs
found in src/*.odin (a test that silently stopped running is a failure too).

Usage: tests/unit.py [-j N] [--no-build] [--only NAME,...] [--perf-strict]
Logs: build/unit/<chunk>.log. Never runs a real pi or claude (the tests use stand-ins).
"""
import argparse
import concurrent.futures as cf
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = "build/pi-desk-core-tests"
LOGS = "build/unit"
TIMES = "build/unit-times.json"
# Tests with time budgets (perf_expect: reported, gating only at 10x): run last, alone, so their
# numbers mean something (see docs/TESTING.md, "Timing tests")
TIMING = [
    "markdown_parse_1mb",
    "markdown_layout_pathological",
    "markdown_html_pathological",
    "reload_burst",
    "editor_perf_50k",
    "syntax_large_parse",
    "buffer_large_file",
]
# Slow tests that get a process of their own (their file's other tests run in another)
ALONE = ["layout_no_overlap_1", "layout_no_overlap_2", "layout_no_overlap_3", "layout_no_overlap_4"]
BUILD = ["odin", "build", "src", "-build-mode:test", "-out:" + BIN,
         "-define:ODIN_TEST_THREADS=1", "-define:PI_DESK_UPDATE_TEST=true"]


def find_tests():
    """(file stem, test name) for every @(test) proc in src/*.odin, in file order."""
    out = []
    for f in sorted(glob.glob(os.path.join(ROOT, "src", "*.odin"))):
        lines = open(f, encoding="utf-8").read().split("\n")
        for i, line in enumerate(lines):
            if re.match(r"\s*@\(test\)", line):
                m = re.search(r"(\w+)\s*::\s*proc", line) or re.match(r"\s*(\w+)\s*::\s*proc", lines[i + 1])
                if not m:
                    sys.exit(f"unit.py: cannot read the test name after {f}:{i + 1}")
                out.append((os.path.basename(f)[:-5], m.group(1)))
    return out


def run_chunk(name, tests, tmp_root, index):
    """Runs tests (names) in one process; returns (name, ok, ran, seconds, log path)."""
    # a short folder: the control socket's path in it must fit in sun_path (104 bytes)
    tmp = os.path.join(tmp_root, "c%d" % index)
    os.makedirs(tmp)
    env = dict(os.environ, TMPDIR=tmp + "/")
    log = os.path.join(LOGS, name + ".log")
    t0 = time.monotonic()
    with open(log, "w") as fh:
        p = subprocess.run([os.path.join(ROOT, BIN), "-tests:" + ",".join(tests)], cwd=ROOT, env=env,
                           stdout=fh, stderr=subprocess.STDOUT)
    secs = time.monotonic() - t0
    text = open(log, errors="replace").read()
    m = re.search(r"Finished (\d+) tests? in", text)
    ran = int(m.group(1)) if m else 0
    ok = p.returncode == 0 and ran == len(tests)
    if ok:
        shutil.rmtree(tmp, ignore_errors=True)
    return name, ok, ran, secs, log


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-j", type=int, default=int(os.environ.get("UNIT_JOBS", "0")) or None,
                    help="parallel processes (default: half the CPUs, at most 6; UNIT_JOBS)")
    ap.add_argument("--no-build", action="store_true", help="use the existing " + BIN)
    ap.add_argument("--only", help="comma-separated test names (still one process per file)")
    ap.add_argument("--perf-strict", action="store_true",
                    help="a time budget over its limit fails the run (DECKHAND_PERF_STRICT=1; a quiet machine only)")
    a = ap.parse_args()
    if a.perf_strict:
        os.environ["DECKHAND_PERF_STRICT"] = "1"
    os.chdir(ROOT)
    jobs = a.j or max(2, min(6, (os.cpu_count() or 4) // 2))

    tests = find_tests()
    names = {n for _, n in tests}
    for n in TIMING + ALONE:
        if n not in names:
            sys.exit(f"unit.py: {n} is listed in TIMING or ALONE but is not a test in src/ (renamed? update the list)")
    if a.only:
        want = set(a.only.split(","))
        unknown = want - names
        if unknown:
            sys.exit(f"unit.py: no such test: {', '.join(sorted(unknown))}")
        tests = [t for t in tests if t[1] in want]

    t_start = time.monotonic()
    if not a.no_build:
        b0 = time.monotonic()
        if subprocess.run(BUILD).returncode != 0:
            sys.exit("unit.py: the test build failed")
        print(f"unit: built {BIN} in {time.monotonic() - b0:.1f} s")

    chunks = {}
    for stem, n in tests:
        if n in ALONE:
            chunks[n] = [n]
        elif n not in TIMING:
            chunks.setdefault(stem, []).append(n)
    timing = [n for _, n in tests if n in TIMING]
    try:
        last = json.load(open(TIMES))
    except (OSError, ValueError):
        last = {}
    order = sorted(chunks, key=lambda c: -last.get(c, len(chunks[c]) * 0.2))

    shutil.rmtree(LOGS, ignore_errors=True)
    os.makedirs(LOGS)
    # /tmp, not $TMPDIR (/var/folders/...): tests nest folders in TMPDIR and put a socket there
    tmp_root = tempfile.mkdtemp(prefix="dku-", dir="/tmp")
    results = []
    p0 = time.monotonic()
    with cf.ThreadPoolExecutor(jobs) as ex:
        futs = [ex.submit(run_chunk, c, chunks[c], tmp_root, i) for i, c in enumerate(order)]
        for f in cf.as_completed(futs):
            results.append(f.result())
    par_secs = time.monotonic() - p0
    t0 = time.monotonic()
    if timing:
        results.append(run_chunk("timing", timing, tmp_root, len(order)))
    timing_secs = time.monotonic() - t0

    if not any(not r[1] for r in results):
        shutil.rmtree(tmp_root, ignore_errors=True)
    ran = sum(r[2] for r in results)
    failed = [r for r in results if not r[1]]
    times = dict(last)
    for name, ok, _, secs, _ in results:
        times[name] = round(secs, 2)
    try:
        json.dump(times, open(TIMES, "w"), indent=0, sort_keys=True)
    except OSError:
        pass
    for name, ok, n, secs, log in failed:
        print(f"\n--- {name}: FAILED ({n}/{len(chunks.get(name, timing))} tests ran) log: {log}")
        lines = open(log, errors="replace").read().splitlines()
        bad = [ln for ln in lines if "[ERROR]" in ln or "[FATAL]" in ln or "failed" in ln.lower()]
        print("\n".join((bad or lines)[-40:]))
        names_ = chunks.get(name, timing)
        print(f"rerun: {BIN} -tests:{','.join(names_)}   (or tests/unit.py --only NAME)")
    over = []
    for _, _, _, _, log in results:
        over += [ln.strip() for ln in open(log, errors="replace") if ln.startswith("PERF OVER BUDGET")]
    if over:
        print(f"unit: perf: {len(over)} over budget (a warning, not a failure: busy machine? "
              f"load {os.getloadavg()[0]:.1f}; rerun with --only NAME --perf-strict on a quiet one):")
        for ln in over:
            print("  " + ln)
            if os.environ.get("GITHUB_ACTIONS") == "true":
                print("::warning::" + ln)
    slow = sorted(results, key=lambda r: -r[3])[:5]
    print("unit: slowest chunks: " + ", ".join(f"{r[0]} {r[3]:.1f}s" for r in slow))
    print(f"unit: {ran}/{len(tests)} tests ran in {len(results)} processes, {jobs} at a time: "
          f"{par_secs:.1f} s, then the timing tests {timing_secs:.1f} s; {time.monotonic() - t_start:.1f} s in all")
    if failed:
        sys.exit(f"unit: FAILED: {', '.join(r[0] for r in failed)}")
    if ran != len(tests):
        sys.exit(f"unit: FAILED: {ran} tests ran, {len(tests)} expected")
    print("unit: all passed")


if __name__ == "__main__":
    main()
