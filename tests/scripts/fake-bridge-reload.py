#!/usr/bin/env python3
"""A fake pi for tests/scripts/reload.sh: a pi-like screen and the pi integration's bridge over
Deckhand's socket (DECKHAND_SOCKET, the single-use DECKHAND_TOKEN). It reports its
session (the --session file Deckhand gave it, so a restart can resume it) and
idle, and answers:
  pi.prompt  the text is the next status: working, idle, waiting, or blocked
             (idle with a background shell: blockers ["shell sh1: npm test"])
  pi.reload  refused unless idle without blockers ("not idle: …", as the real
             bridge does); else "reloaded" (counted on screen and in
             $RELOAD_LOG) and idle again
  pi.wait_idle  ok when idle without blockers, else "timeout" (the real
             bridge waits up to timeout_ms; asked before a restart)
Each start is logged to $RELOAD_LOG too ("start <session>"). Args: pi's."""
import json, os, select, socket, sys

args = sys.argv[1:]
path = args[args.index("--session") + 1] if "--session" in args else ""
who = os.path.basename(path).rsplit("_", 1)[-1].removesuffix(".jsonl") if path else "new"
log = os.environ.get("RELOAD_LOG", "")


def note(line):
    if log:
        with open(log, "a") as f:
            f.write(line + "\n")


sock = socket.socket(socket.AF_UNIX)
sock.connect(os.environ["DECKHAND_SOCKET"])
state = {"agent": "idle", "waiting": False, "blockers": []}
reloads = 0


def send(m):
    m.setdefault("v", 1)
    sock.sendall((json.dumps(m) + "\n").encode())


def status():
    send({"id": "st", "type": "pi.status", **state})


def show(what):
    print("status: %s" % what, flush=True)


note("start %s" % who)
send({"id": "h", "type": "hello", "token": os.environ["DECKHAND_TOKEN"]})
send({"id": "s", "type": "pi.session", "pi_session_id": who, "session_file": path, "cwd": os.getcwd()})
print("\x1b[2J\x1b[H\x1b[1mpi\x1b[0m  fake reload bridge · session %s\n" % who, flush=True)
status()
buf = b""
while True:
    r, _, _ = select.select([sock], [], [], 1)
    if not r:
        continue
    data = sock.recv(65536)
    if not data:
        break
    buf += data
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        try:
            m = json.loads(line)
        except ValueError:
            continue
        t = m.get("type")
        if t == "pi.prompt":
            s = m.get("text", "idle")
            state = {"agent": "working" if s == "working" else "idle", "waiting": s == "waiting", "blockers": ["shell sh1: npm test"] if s == "blocked" else []}
            status()
            show(s)
            send({"id": m["id"], "type": "result", "result": {"ok": True}})
        elif t == "pi.wait_idle":
            idle = state["agent"] != "working" and not state["waiting"] and not state["blockers"]
            note("wait_idle %s %s" % (who, "ok" if idle else "timeout"))
            send({"id": m["id"], "type": "result", "result": {"ok": True} if idle else {"ok": False, "error": "timeout"}})
        elif t == "pi.reload":
            busy = (["agent working"] if state["agent"] == "working" else []) + (["a dialog is open"] if state["waiting"] else []) + state["blockers"]
            if busy:
                send({"id": m["id"], "type": "result", "result": {"ok": False, "error": "not idle: " + ", ".join(busy)}})
                continue
            reloads += 1
            note("reload %s" % who)
            show("reloaded #%d" % reloads)
            send({"id": m["id"], "type": "result", "result": {"ok": True}})
            status()
