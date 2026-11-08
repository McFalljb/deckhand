#!/usr/bin/env python3
"""Which fixed `wait`s in the scene scripts can become `eventually` (docs/TESTING.md, "Waits").

Run the scenes with DECKHAND_WAIT_AUDIT=1 (the app logs, for every `wait` followed by checks,
whether each check already held before the line ahead of the wait ran (A), when the wait began
(B), and after it (C)), then:

  tests/wait_audit.py LOG...            report, per script, which waits convert and which stay
  tests/wait_audit.py --apply LOG...    rewrite those `wait N` lines as `eventually`

A wait converts only when every check after it failed before the line ahead of it ran (A), or,
with no such line (the script's start, a check right before the wait), when the wait began (B),
and passed after it (C), in every run seen. A check that already held before the action did not
need the wait to become true: it may check that something stays as it was, which `eventually`
would pass at once; that wait is kept. So is a script's first wait (the app settling after its
start is also what the lines after the checks need), and every wait before a check that something is not
there (assert_not_*, "-", an empty assert_tip...), whatever the audit saw. Waits followed by no
check are not touched here.
"""
import collections
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAT = re.compile(r"\] AUDIT (script (\S+)|([ABC]) (\d+) (\d+) (pass|fail))")


def negative(check):
    """A check that something is not there (or none is): its wait is always kept."""
    cmd, _, rest = check.strip().partition(" ")
    rest = rest.strip()
    if cmd.startswith("assert_not_"):
        return True
    if cmd in ("assert_toast", "assert_revealed", "assert_clipboard", "assert_link") and rest == "-":
        return True
    if cmd == "assert_tip" and rest == "":
        return True
    if cmd == "assert_drawn_selection" and rest == "0":
        return True
    if cmd == "assert_rows" and rest.endswith(" -"):
        return True
    return False


# the checks `eventually` retries (autotest.odin, script_is_check)
CHECKS = {"assert_file", "assert_not_file", "assert_tip", "assert_drawn", "assert_not_drawn", "assert_md",
          "assert_not_md", "assert_opened", "assert_menurows", "assert_revealed", "assert_toast", "assert_clipboard",
          "assert_notice", "assert_files", "assert_not_files", "assert_rows", "assert_link", "assert_drawn_selection",
          "assert_screen", "assert_not_screen", "assert_palette", "assert_selection", "hittest", "assert_in_window",
          "assert_window", "assert_menu", "assert_state", "assert_result", "assert_finished"}
OTHER_CHECKS = ("web_assert", "web_title", "web_pixel", "page_assert", "act_assert", "agent_assert", "annot_assert", "beeps")


def block(lines, w):
    """The check lines right after line w (1-based): every assert-like line, retried or not."""
    out = []
    for l in lines[w:]:
        t = l.strip()
        if not t or t.startswith("#"):
            continue
        c = t.split(" ")[0]
        if not (c in CHECKS or c.startswith("assert_") or c in OTHER_CHECKS):
            break
        out.append(t)
    return out


def parse(paths):
    seen = collections.defaultdict(lambda: collections.defaultdict(lambda: collections.defaultdict(set)))
    for p in paths:
        script = None
        for line in open(p, errors="replace"):
            m = PAT.search(line)
            if not m:
                continue
            if m.group(2):
                script = os.path.normpath(os.path.join(ROOT, m.group(2))) if not os.path.isabs(m.group(2)) else m.group(2)
                continue
            if script:
                phase, w, k, r = m.group(3), int(m.group(4)), int(m.group(5)), m.group(6)
                seen[script][w][(phase, k)].add(r)
    return seen


def main():
    args = sys.argv[1:]
    apply = "--apply" in args
    logs = [a for a in args if a != "--apply"]
    seen = parse(logs)
    total_ms = kept_ms = 0
    for script in sorted(seen):
        lines = open(script).read().split("\n")
        changed = False
        for w, obs in sorted(seen[script].items()):
            line = lines[w - 1].strip()
            m = re.match(r"wait (\d+)$", line)
            if not m:
                continue
            ms = int(m.group(1))
            ks = sorted({k for (_, k) in obs})
            why = None
            checks = block(lines, w)
            neg = [c for c in checks if negative(c)]
            other = [c for c in checks if c.split(" ")[0] not in CHECKS]
            start = not any(l.strip() and not l.strip().startswith("#") for l in lines[:w - 1])
            if start:
                why = "the script's first line: it also lets the app settle for the lines after the checks"
            elif neg:
                why = f"a check that something is not there: {neg[0]!r}"
            elif other:
                why = f"a check `eventually` does not retry: {other[0]!r}"
            elif len(ks) != len(checks):
                why = f"the audit saw {len(ks)} of its {len(checks)} checks"
            for k in ks if not why else []:
                c, a, b = obs.get(("C", k), set()), obs.get(("A", k)), obs.get(("B", k), set())
                if c != {"pass"}:
                    why = f"check {k} did not pass after the wait ({sorted(c)})"
                elif a is not None:
                    if "pass" in a:
                        why = f"check {k} held before the line ahead of the wait"
                elif "pass" in b or not b:
                    why = f"check {k} held when the wait began (no line ahead of it to compare)"
                if why:
                    break
            rel = os.path.relpath(script, ROOT)
            if why:
                kept_ms += ms
                print(f"keep    {rel}:{w} wait {ms}: {why}")
            else:
                total_ms += ms
                print(f"convert {rel}:{w} wait {ms}")
                if apply:
                    lines[w - 1] = lines[w - 1].replace(line, "eventually")
                    changed = True
        if changed:
            open(script, "w").write("\n".join(lines))
    # a right-click opens its menu at once (menu_open, in the click's own event): the wait before
    # clickmenu goes (clickmenu waits for a frame drawn after the click, and for the row), also
    # with revealed_clear, clipboard_clear or toast_clear between them
    menu_ms = 0
    for script in sorted({os.path.normpath(p) for p in seen}):
        lines = open(script).read().split("\n")
        cmds = [(i, l.strip()) for i, l in enumerate(lines) if l.strip() and not l.strip().startswith("#")]
        drop = []
        for n, (i, l) in enumerate(cmds[1:-1], 1):
            m = re.match(r"wait (\d+)$", l)
            k = n + 1  # past lines that only forget what was recorded (revealed_clear...)
            while k < len(cmds) - 1 and re.match(r"(revealed_clear|clipboard_clear|toast_clear)$", cmds[k][1]):
                k += 1
            if m and cmds[n - 1][1].startswith("rclickid ") and cmds[k][1].startswith("clickmenu "):
                drop.append(i)
                menu_ms += int(m.group(1))
                print(f"drop    {os.path.relpath(script, ROOT)}:{i + 1} wait {m.group(1)} (rclickid, then clickmenu)")
        if apply and drop:
            lines = [l for i, l in enumerate(lines) if i not in drop]
            open(script, "w").write("\n".join(lines))
    print(f"convertible: {total_ms / 1000:.1f} s of waits; menu waits dropped: {menu_ms / 1000:.1f} s; kept: {kept_ms / 1000:.1f} s")


if __name__ == "__main__":
    main()
