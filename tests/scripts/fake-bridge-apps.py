#!/usr/bin/env python3
"""A fake pi for tests/scripts/app-open.sh: a pi-like screen and the pi integration's bridge over pi-desk's
socket (DECKHAND_SOCKET, the single-use DECKHAND_TOKEN: caller panel), opening and managing app
tabs as the pi integration's app_open, app_restart and app_close tools do. A line typed into the tab says what
to try; each result is logged to $APPS_LOG and the screen then says "done <word>":
  open     app_declared; new_app_tab by name (its own session: the first time the user is asked);
           the same naming every other session id; an argv; a command line; an undeclared name
  again    its app tab (the one the user allowed) and tab.describe until it answers; the same
           name again (no question now), closed again at once
  shot     app_screenshot of its app tab while hidden, twice (a fresh frame each time)
  others   app_restart, app_close and app_call on every tab id that is not its own session's
  restart  app_restart on the app tab it opened, then tab.describe until it answers
  close    app_close on it
Args: pi's."""
import json, os, select, socket, sys

log = os.environ.get("APPS_LOG", "")
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
print("\x1b[2J\x1b[H\x1b[1mpi\x1b[0m  fake apps bridge\n", flush=True)

mine = 0  # the app tab it opened
own_session = 0


def own_tabs():
    st = call({"type": "get_state"}).get("data") or {}
    return {t.get("id") for s in st.get("open_sessions", []) for t in s.get("tabs", [])}


def describe(tab):
    """tab.describe until the app answers (it connects after it starts): whether it did."""
    for _ in range(40):
        if call({"type": "app_call", "tab_id": tab, "method": "tab.describe", "timeout_ms": 2000}).get("ok"):
            return True
        select.select([], [], [], 0.25)
    return False


def word(w):
    global mine, own_session
    if w == "open":
        r = call({"type": "app_declared"})
        d = r.get("data") or {}
        own_session = d.get("session", 0)
        note("declared ok=%s names=%s" % (r.get("ok"), ",".join(a.get("name", "") for a in d.get("apps", []))))
        r = call({"type": "new_app_tab", "name": "fake"})
        note("open ok=%s error=%s" % (r.get("ok"), r.get("error")))
        oks = 0
        for sid in range(1, 80):
            if sid == own_session:
                continue
            r = call({"type": "new_app_tab", "name": "fake", "session": sid})
            if r.get("ok"):
                oks += 1
            elif sid == 1:
                note("other error=%s" % r.get("error"))
        note("other sessions opened=%d" % oks)
        r = call({"type": "new_app_tab", "argv": ["/bin/echo", "hi"]})
        note("argv ok=%s error=%s" % (r.get("ok"), r.get("error")))
        r = call({"type": "new_app_tab", "command": "echo hi"})
        note("command ok=%s" % r.get("ok"))
        r = call({"type": "new_app_tab", "name": "nope"})
        note("nope ok=%s error=%s" % (r.get("ok"), r.get("error")))
    elif w == "again":
        st = call({"type": "get_state"}).get("data") or {}
        tabs = [t for s in st.get("open_sessions", []) for t in s.get("tabs", []) if t.get("kind") == "app"]
        mine = tabs[0]["id"] if tabs else 0
        note("opened tabs=%d" % len(tabs))
        note("describe ok=%s" % describe(mine))
        r = call({"type": "new_app_tab", "name": "fake"})
        note("again ok=%s" % r.get("ok"))
        if r.get("created_id"):
            note("again closed=%s" % call({"type": "app_close", "tab_id": r["created_id"]}).get("ok"))
    elif w == "shot":
        seqs = []
        for i in range(2):
            r = call({"type": "app_screenshot", "tab_id": mine})
            if r.get("pending"):
                r = finished(r)
            d = r.get("data") or {}
            ok = r.get("ok") and str(d.get("path", "")).endswith(".png") and os.path.getsize(d.get("path")) > 8
            note("shot%d ok=%s visible=%s" % (i + 1, ok, d.get("visible")))
            seqs.append(d.get("seq", 0))
        note("fresh=%s" % (seqs[1] > seqs[0] > 0))
    elif w == "others":
        own = own_tabs()
        oks = 0
        for tid in range(1, 120):
            if tid in own:
                continue
            for t in ("app_restart", "app_close"):
                if call({"type": t, "tab_id": tid}).get("ok"):
                    oks += 1
            if call({"type": "app_call", "tab_id": tid, "method": "tab.describe", "timeout_ms": 500}).get("ok"):
                oks += 1
        note("others acted=%d" % oks)
    elif w == "restart":
        r = call({"type": "app_restart", "tab_id": mine})
        note("restart ok=%s" % r.get("ok"))
        note("describe again ok=%s" % describe(mine))
    elif w == "close":
        r = call({"type": "app_close", "tab_id": mine})
        note("close ok=%s" % r.get("ok"))
    print("done %s" % w, flush=True)


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
