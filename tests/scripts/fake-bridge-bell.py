#!/usr/bin/env python3
"""A fake pi for tests/scripts/bell.sh: a pi-like screen and the pi integration's bridge over
Deckhand's socket (DECKHAND_SOCKET, the single-use DECKHAND_TOKEN). It plays a
status script per session (aaaa-1, bbbb-2 of the fake store), BELL_DELAY
seconds apart (default 5):
  aaaa-1  working, then idle      (a run that ends: "finished")
  bbbb-2  working, then waiting   (a dialog: "waiting for you")
It also answers pi.prompt: the prompt's text is the next status (working,
idle, error, waiting), or "later:STATUS" for that status BELL_DELAY seconds
on. It stays connected, like a bridge.
Args: pi's (--session/--session-id ...)."""
import json, os, select, socket, sys, time

args = sys.argv[1:]
who = next((a for a in ("aaaa-1", "bbbb-2") if any(a in x for x in args)), "new-1")
sock = socket.socket(socket.AF_UNIX)
sock.connect(os.environ["DECKHAND_SOCKET"])


def send(m):
    m.setdefault("v", 1)
    sock.sendall((json.dumps(m) + "\n").encode())


def status(s):
    send({"id": "st", "type": "pi.status", "agent": "idle" if s == "waiting" else s, "waiting": s == "waiting", "blockers": []})
    print("status: %s" % s, flush=True)


send({"id": "h", "type": "hello", "token": os.environ["DECKHAND_TOKEN"]})
send({"id": "s", "type": "pi.session", "pi_session_id": who, "session_file": "", "cwd": os.getcwd()})
print("\x1b[2J\x1b[H\x1b[1mpi\x1b[0m  fake bell bridge · session %s\n" % who, flush=True)
plan = {"aaaa-1": ["working", "idle"], "bbbb-2": ["working", "waiting"]}.get(who, ["idle"])
delay = float(os.environ.get("BELL_DELAY", "5"))
due = time.time()
buf = b""
while True:
    if plan and time.time() >= due:
        status(plan.pop(0))
        due = time.time() + delay
    r, _, _ = select.select([sock], [], [], 0.2)
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
        if m.get("type") == "pi.prompt":
            text = m.get("text", "idle")
            if text.startswith("later:"):
                plan.append(text[6:])
                due = time.time() + delay
            else:
                status(text)
            send({"id": m["id"], "type": "result", "result": {"ok": True}})
