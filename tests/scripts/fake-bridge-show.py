"""A fake pi for tests/scripts/agent-show.sh: a pi-like screen and the pi integration's bridge over
pi-desk's socket (DECKHAND_SOCKET, the single-use DECKHAND_TOKEN: caller panel), showing the user files
as the pi integration's desk_show tool does (show_file). Typing "show" and Enter runs, logging each
result to $SHOW_LOG, then the screen says "done show":
  show_file README.md (anchor setup), notes.txt (line 3), $OUTSIDE_FILE (absolute, outside every
  project); the same naming every other session id; logo.png (binary); README.md again (already open).
Args: pi's."""
import json, os, select, socket, sys

log = os.environ.get("SHOW_LOG", "")
sock = socket.socket(socket.AF_UNIX)
sock.connect(os.environ["DECKHAND_SOCKET"])
buf = b""
n = 0


def note(line):
    if log:
        with open(log, "a") as f:
            f.write(line + "\n")


def send(m):
    m.setdefault("v", 1)
    sock.sendall((json.dumps(m) + "\n").encode())


def reply(want):
    """Lines until the one with id `want` (events and other replies skipped)."""
    global buf
    while True:
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("id") == want:
                return m
        data = sock.recv(1 << 20)
        if not data:
            sys.exit(0)
        buf += data


def call(cmd):
    global n
    n += 1
    cid = "c%d" % n
    send({"id": cid, "type": "command", "command": cmd})
    m = reply(cid)
    r = m.get("result") or {}
    if r.get("pending"):
        r = dict(r, request_id=m.get("request_id"))
    return r


def finished(r):
    """A long-running command's finished event (pi-desk sends it to the requester)."""
    global buf
    want = r.get("request_id")
    while True:
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("event") == "finished" and m.get("request_id") == want:
                return m.get("result") or {}
        data = sock.recv(1 << 20)
        if not data:
            sys.exit(0)
        buf += data


send({"id": "h", "type": "hello", "token": os.environ["DECKHAND_TOKEN"]})
reply("h")
send({"id": "st", "type": "pi.status", "agent": "idle", "waiting": False, "blockers": []})
print("\x1b[2J\x1b[H\x1b[1mpi\x1b[0m  fake show bridge\n", flush=True)


def shown(name, r):
    d = r.get("data") or {}
    if r.get("ok"):
        note("%s ok=True kind=%s session=%s again=%s" % (name, d.get("kind"), d.get("session"), d.get("already_open")))
    else:
        note("%s ok=False code=%s hint=%s error=%s" % (name, d.get("code"), bool(d.get("hint")), r.get("error")))
    return r


def word(w):
    if w != "show":
        return
    first = shown("readme", call({"type": "show_file", "path": "README.md", "anchor": "setup"}))
    own = (first.get("data") or {}).get("session", 0)
    shown("notes", call({"type": "show_file", "path": "notes.txt", "line": 3}))
    shown("outside", call({"type": "show_file", "path": os.environ.get("OUTSIDE_FILE", "")}))
    oks, codes = 0, set()
    for sid in range(1, 80):
        if sid == own:
            continue
        r = call({"type": "show_file", "path": "notes.txt", "session": sid})
        if r.get("ok"):
            oks += 1
        else:
            codes.add((r.get("data") or {}).get("code"))
    note("other sessions shown=%d codes=%s" % (oks, ",".join(sorted(str(c) for c in codes))))
    shown("logo", call({"type": "show_file", "path": "logo.png"}))
    again = shown("again", call({"type": "show_file", "path": "README.md"}))
    note("same tab=%s" % (again.get("created_id") == first.get("created_id")))


typed = b""
while True:
    r, _, _ = select.select([sys.stdin, sock], [], [], 1)
    if sock in r:
        data = sock.recv(1 << 20)
        if not data:
            break
        buf += data
    if sys.stdin in r:
        data = os.read(sys.stdin.fileno(), 4096)
        if not data:
            break
        typed += data.replace(b"\r", b"\n")
        while b"\n" in typed:
            line, typed = typed.split(b"\n", 1)
            line = line.decode(errors="replace").strip()
            if line:
                word(line)
                print("done %s" % line, flush=True)
