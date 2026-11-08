#!/usr/bin/env python3
"""A fake pi for tests/scripts/keep-sessions.sh. It prints "ARGS: <pi's args without -e pairs>"
(the scene waits for it) and holds a bridge connection to Deckhand's socket as the pi integration
does: hello with the single-use DECKHAND_TOKEN, and whenever the connection drops (Deckhand quit
or was killed), hello again with the reconnect token that hello gave. Kept running by the session
holder, it is what tells whether a relaunch still knows its token. Every hello's outcome goes to
$KEEP_BRIDGE_LOG: "hello ok <tab id>" or "hello error <why>" (a hello before its terminal was
adopted is refused: it retries)."""
import json, os, socket, sys, time

args = sys.argv[1:]
while args[:1] == ["-e"]:
    args = args[2:]
print("ARGS: " + " ".join(args), flush=True)
path, token = os.environ["DECKHAND_SOCKET"], os.environ["DECKHAND_TOKEN"]
log = os.environ.get("KEEP_BRIDGE_LOG", "")


def note(line):
    if log:
        with open(log, "a") as f:
            f.write(line + "\n")


while True:
    try:
        s = socket.socket(socket.AF_UNIX)
        s.connect(path)
        s.sendall((json.dumps({"id": "h", "v": 1, "type": "hello", "token": token}) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                raise OSError("closed")
            buf += chunk
        r = json.loads(buf.split(b"\n", 1)[0]).get("result", {})
        if r.get("ok"):
            note(f"hello ok {r['data']['tab_id']}")
            token = r["data"].get("reconnect_token", token)
            while s.recv(65536):  # until Deckhand goes away
                pass
        else:
            note(f"hello error {r.get('error')}")
        s.close()
    except OSError:
        pass
    time.sleep(0.3)
