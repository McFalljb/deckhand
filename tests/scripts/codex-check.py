#!/usr/bin/env python3
"""Checks what the fake codex logged in the codex scene (tests/scripts/codex.sh): every start's
argv as Codex reads it, every hook's stdout empty and its exit 0, no Deckhand text ever ran as a
command or a mention. Usage: codex-check.py LOG"""
import json
import sys

ok = True


def bad(msg):
    global ok
    ok = False
    print("FAILED:", msg)


rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
starts = [r["argv"] for r in rows if "argv" in r]
hooks = [r for r in rows if "hook" in r]
prompts = [r["prompt"] for r in rows if "prompt" in r]
if len(starts) < 4:
    bad(f"{len(starts)} starts (want at least 4)")
for a in starts:
    if "--no-daemon" not in a:
        bad("a start without --no-daemon: " + " ".join(a[:4]))
    if any(x in a for x in ("--dangerously-bypass-hook-trust", "-s", "-a", "-m", "-p")):
        bad("a start overriding the user's settings")
resumes = [a for a in starts if a[:1] == ["resume"]]
if not resumes or any(a[1] != "01a1d0d6-5353-7ff3-9308-ff91070ad530" for a in resumes):
    bad("no resume of the conversation by its id")
events = {h["hook"] for h in hooks}
for e in ("SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"):
    if e not in events:
        bad(f"no {e} hook ran")
for h in hooks:
    if h.get("timeout"):
        bad(f"{h['hook']} timed out")
    elif h.get("out"):
        bad(f"{h['hook']} printed {h['out'][:80]!r} (Codex would read it)")
    elif h.get("exit") != 0:
        bad(f"{h['hook']} exited {h.get('exit')}: {h.get('err', '')[:200]}")
for p in prompts:
    lead = p.lstrip(" \t\n")
    if lead[:1] in ("/", "$") or (lead[:1] == "!" and not lead.startswith(("!perm", "!ask", "!exit", "!quit", "!mcp"))):
        bad(f"a command reached codex: {p!r}")
if "from atlas" not in prompts:
    bad("the held prompt never arrived")
print("ok: codex log" if ok else "codex log FAILED")
sys.exit(0 if ok else 1)
