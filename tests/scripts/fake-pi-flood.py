#!/usr/bin/env python3
"""A fake pi for tests/scripts/hidden-window.sh: a pi-like screen and the pi integration's bridge
over Deckhand's socket (DECKHAND_SOCKET, the single-use DECKHAND_TOKEN). On the line "flood" (typed
into its terminal) it reports working, prints FLOOD_MIB MiB (default 20) of numbered lines as fast
as the terminal takes them, then clears the screen, prints a final screen and reports waiting (a
question for the user: a bell entry and, behind, an OS notification). It stays connected, like a
bridge. Args: pi's (--session/--session-id ...), ignored."""
import json, os, select, socket, sys

sock = socket.socket(socket.AF_UNIX)
sock.connect(os.environ["DECKHAND_SOCKET"])
out = sys.stdout.buffer


def send(m):
    m.setdefault("v", 1)
    sock.sendall((json.dumps(m) + "\n").encode())


def status(s):
    send({"id": "st", "type": "pi.status", "agent": "idle" if s == "waiting" else s, "waiting": s == "waiting", "blockers": []})


def flood(mib):
    status("working")
    line = 0
    total = mib << 20
    sent = 0
    while sent < total:
        chunk = b"".join(b"flood %08d %s\r\n" % (line + i, b"x" * 60) for i in range(1024))
        line += 1024
        out.write(chunk)
        out.flush()
        sent += len(chunk)
    # the final screen: what the hash is checked against once the window is back
    out.write(b"\x1b[2J\x1b[H\x1b[1mpi\x1b[0m  fake flood pi\r\n\r\nFLOOD DONE %d lines %d bytes\r\n" % (line, sent))
    out.flush()
    status("waiting")


send({"id": "h", "type": "hello", "token": os.environ["DECKHAND_TOKEN"]})
send({"id": "s", "type": "pi.session", "pi_session_id": "hhhh-1", "session_file": "", "cwd": os.getcwd()})
out.write(b"\x1b[2J\x1b[H\x1b[1mpi\x1b[0m  fake flood pi \xc2\xb7 ready\r\n")
out.flush()
status("idle")
mib = int(os.environ.get("FLOOD_MIB", "20"))
buf, typed = b"", b""
while True:
    r, _, _ = select.select([sock, sys.stdin], [], [], 1.0)
    if sock in r:
        data = sock.recv(65536)
        if not data:
            break
        buf += data
        buf = buf.rsplit(b"\n", 1)[-1] # replies: nothing to do with them
    if sys.stdin in r:
        data = os.read(sys.stdin.fileno(), 4096)
        if not data:
            break
        typed += data
        while b"\n" in typed or b"\r" in typed:
            cut = min(i for i in (typed.find(b"\n"), typed.find(b"\r")) if i >= 0)
            cmd, typed = typed[:cut].strip(), typed[cut + 1:]
            if cmd == b"flood":
                flood(mib)
