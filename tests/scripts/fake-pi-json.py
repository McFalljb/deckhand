#!/usr/bin/env python3
"""A fake `pi --mode json` for job runs (tests/scripts/jobs.sh).

The prompt (the last argument) picks the behaviour:
  OK        one tool call, a summary with the scheduled time, $0.05, exit 0
  SLOW N    events once a second for N seconds, then OK
  COSTLY    $0.30 a turn until stopped (a per-run max_cost stops it)
  SPEND     $3.00 at once, then 3 s of work, then a summary (a daily limit set meanwhile)
  LOOP      the same tool call again and again
  SILENT    the session header, then nothing (the stall watchdog)
  FAIL      an assistant error, exit 1
  BLOCKED   a guardrails "Needs user approval" result, then a summary with Needs you
  SECRET    a summary holding a secret-shaped string (redaction)
It reads its arguments the way pi 1.4 does (dist/cli/args.js): an argument
starting with "-" before `--` is an option (unknown ones are errors), one
starting with "@" is a file to attach (anywhere, after `--` too): this fake
refuses both, so a prompt passed unguarded fails its run.
It writes its arguments and environment to $HOME/pi-env-<job>.txt.
"""
import json, os, sys, time

def out(o):
    sys.stdout.write(json.dumps(o) + "\n")
    sys.stdout.flush()

def assistant(text, cost=0.0, stop="stop", err=None):
    m = {"role": "assistant", "content": [{"type": "text", "text": text}], "stopReason": stop,
         "usage": {"input": 10, "output": 5, "totalTokens": 15, "cost": {"total": cost}}}
    if err: m["errorMessage"] = err
    out({"type": "message_end", "message": m})
    out({"type": "turn_end", "message": m, "toolResults": []})

WITH_VALUE = {"--mode", "--session-dir", "--session-id", "--model", "--append-system-prompt", "--tools", "--exclude-tools"}
FLAGS = {"--no-mcp"}
messages, args, i = [], sys.argv[1:], 0
while i < len(args):
    a = args[i]
    if a == "--":
        for p in args[i + 1:]:
            if p.startswith("@"):
                sys.stderr.write(f"fake pi: refusing to attach file {p[1:]!r}\n"); sys.exit(2)
            messages.append(p)
        break
    if a in WITH_VALUE: i += 2; continue
    if a in FLAGS: i += 1; continue
    if a.startswith("@"):
        sys.stderr.write(f"fake pi: refusing to attach file {a[1:]!r}\n"); sys.exit(2)
    if a.startswith("-"):
        sys.stderr.write(f"Unknown option: {a}\n"); sys.exit(2)
    messages.append(a); i += 1
prompt = " ".join(messages).strip()
job = os.environ.get("PI_DESK_JOB", "x")
with open(os.path.join(os.environ.get("HOME", "/tmp"), f"pi-env-{job}.txt"), "w") as f:
    f.write("ARGS: " + " ".join(sys.argv[1:]) + "\n")
    for k in sorted(os.environ): f.write(f"{k}={os.environ[k]}\n")

out({"type": "session", "version": 3, "id": "fake", "cwd": os.getcwd()})
out({"type": "agent_start"})
word = prompt.split()[0].lstrip("-@") if prompt.split() else ""
sched = os.environ.get("PI_DESK_SCHEDULED_AT", "")

def ok(extra=""):
    out({"type": "tool_execution_start", "toolCallId": "t1", "toolName": "bash", "args": {"command": "ls"}})
    out({"type": "tool_execution_end", "toolCallId": "t1", "toolName": "bash", "result": {"content": [{"type": "text", "text": "a b"}]}, "isError": False})
    assistant(f"Looked around.\n\n## Summary\nAll good, scheduled {sched}{extra}\nmore detail\n", cost=0.05)
    out({"type": "agent_settled", "aborted": False})

if word == "OK":
    ok()
elif word == "SLOW":
    n = int(prompt.split()[1]) if len(prompt.split()) > 1 else 5
    for i in range(n):
        out({"type": "turn_start"})
        time.sleep(1)
    ok()
elif word == "COSTLY":
    for i in range(60):
        assistant("thinking", cost=0.30)
        time.sleep(0.3)
    ok()
elif word == "SPEND":
    assistant("spent a lot", cost=3.0)
    for i in range(3):
        out({"type": "turn_start"})
        time.sleep(1)
    assistant("## Summary\nSpent $3 on purpose\n")
    out({"type": "agent_settled", "aborted": False})
elif word == "LOOP":
    for i in range(200):
        out({"type": "tool_execution_start", "toolCallId": f"l{i}", "toolName": "read", "args": {"path": "same.txt"}})
        out({"type": "tool_execution_end", "toolCallId": f"l{i}", "toolName": "read", "result": {"content": [{"type": "text", "text": "x"}]}, "isError": False})
        time.sleep(0.2)
elif word == "SILENT":
    time.sleep(120)
elif word == "FAIL":
    assistant("", stop="error", err="503 upstream overloaded")
    sys.exit(1)
elif word == "BLOCKED":
    out({"type": "tool_execution_start", "toolCallId": "b1", "toolName": "bash", "args": {"command": "git push --force"}})
    out({"type": "tool_execution_end", "toolCallId": "b1", "toolName": "bash", "isError": True,
         "result": {"content": [{"type": "text", "text": "Needs user approval (force push), and no UI is available. Report it to the orchestrator instead."}]}})
    assistant("## Summary\nCould not push: blocked\n\n## Needs you\n- approve the force push\n")
elif word == "SECRET":
    # the fake key in pieces: no whole key-shaped string in the source (jobs.sh greps for it)
    assistant("## Summary\nFound key " + "sk-" + "ant-api03-" + "ABCDEFGHIJKLMNOPQRSTUVWX" + " in the log\n")
else:
    assistant("I do not know this prompt")
