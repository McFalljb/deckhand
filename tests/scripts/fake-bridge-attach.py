#!/usr/bin/env python3
"""A fake pi for tests/scripts/comments.sh: a pi-like screen and pi-kit's bridge over pi-desk's
socket (PI_DESK_SOCKET, the single-use PI_DESK_TOKEN), playing the pending-comments half of the
pi-tab schema (docs/PROTOCOL.md §4):
  pi.attach        kept (the next typed line takes it); logged with its image count, whether
                   each image is a PNG, and its text's first comment line
  pi.attach_clear  forgotten
  pi.prompt        logged with its image count (Send now)
A line typed into the tab (pi's input) is the user's next message: with an attachment held it
logs "message <line> took <id>" and answers pi.attached; "quit-bridge" hangs up (pi keeps
running, with no bridge). Everything goes to $ATTACH_LOG and, short, to the screen. Args: pi's."""
import base64, json, os, select, socket, sys

log = os.environ.get("ATTACH_LOG", "")
args = sys.argv[1:]
who = args[args.index("--session-id") + 1] if "--session-id" in args else "wwww-1"


def note(line):
    print(line, flush=True)
    if log:
        with open(log, "a") as f:
            f.write(line + "\n")


sock = socket.socket(socket.AF_UNIX)
sock.connect(os.environ["PI_DESK_SOCKET"])


def send(m):
    m.setdefault("v", 1)
    sock.sendall((json.dumps(m) + "\n").encode())


def images(m):
    imgs = m.get("images") or []
    png = all(base64.b64decode(i.get("data", ""))[:8] == b"\x89PNG\r\n\x1a\n" for i in imgs)
    return "images=%d png=%s" % (len(imgs), "yes" if png else "no")


def items(text):
    """The block's item lines (what was picked) and how many lines read as a "Comment:"."""
    its = [l for l in text.splitlines() if l[:1].isdigit() and ". [" in l]
    n = sum(1 for l in text.splitlines() if l.strip().startswith("Comment:"))
    return its, n


def first_comment(text):
    for l in text.splitlines():
        if l.strip().startswith("Comment:"):
            return l.strip()
    return "-"


print("\x1b[2J\x1b[H\x1b[1mpi\x1b[0m  fake attach bridge\n", flush=True)
send({"id": "h", "type": "hello", "token": os.environ["PI_DESK_TOKEN"]})
send({"id": "s", "type": "pi.session", "pi_session_id": who, "session_file": "", "cwd": os.getcwd()})
send({"id": "st", "type": "pi.status", "agent": "idle", "waiting": False, "blockers": []})
held = None
buf = b""
typed = b""
fds = [sock, sys.stdin]
while True:
    r, _, _ = select.select(fds, [], [], 1)
    if sys.stdin in r:
        data = os.read(sys.stdin.fileno(), 4096)
        if not data:
            fds.remove(sys.stdin)
            continue
        typed += data.replace(b"\r", b"\n")
        while b"\n" in typed:
            line, typed = typed.split(b"\n", 1)
            line = line.decode(errors="replace").strip()
            if not line:
                continue
            if line == "quit-bridge":
                note("bridge gone")
                if sock in fds:
                    fds.remove(sock)
                    sock.close()
                continue
            if held is not None:
                note("message %s took %s" % (line, held))
                send({"id": "a%s" % held, "type": "pi.attached", "attachment_id": held})
                held = None
            else:
                note("message %s alone" % line)
    if sock not in fds or sock not in r:
        continue
    data = sock.recv(1 << 20)
    if not data:
        fds.remove(sock)
        continue
    buf += data
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        try:
            m = json.loads(line)
        except ValueError:
            continue
        t = m.get("type")
        if t == "pi.attach":
            held = m.get("attachment_id")
            note("attach %s %s %s" % (held, images(m), first_comment(m.get("text", ""))))
            its, n = items(m.get("text", ""))
            note("attach_items %d comment_lines %d first %s" % (len(its), n, its[0] if its else "-"))
        elif t == "pi.attach_clear":
            held = None
            note("attach_clear")
        elif t == "pi.prompt":
            note("prompt %s %s" % (images(m), first_comment(m.get("text", ""))))
        else:
            continue
        send({"id": m["id"], "type": "result", "result": {"ok": True}})
