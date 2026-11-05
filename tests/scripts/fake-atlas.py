#!/usr/bin/env python3
"""A fake pi for Atlas (pi-desk's agent) in its terminal tab, for tests/scripts/agent.sh.

It plays pi's terminal UI just enough and the pi integration's bridge over pi-desk's
socket (DECKHAND_SOCKET, the single-use DECKHAND_TOKEN): hello, pi.session,
pi.status. It prints what pi-desk gave it: --model, --append-system-prompt
(and the prompt's first line), whether DECKHAND_CONTROL_TOKEN is set (never
the token). Keys (the terminal is raw):
  Ctrl+L       "[model selector]" with a few models (as pi's app.model.select)
  a line "go"  a run: working, a reply, then idle
  a line "ask" a dialog: waiting until the next line
  Enter        anything else is echoed as a user message
  a bracketed paste (it turns the mode on, as pi does): "[pasted N lines]" and
               the lines, not sent (pi's editor keeps a paste until Enter)
Args: pi's (-e per extension of Deckhand's pi integration, --session-dir, --session/--session-id, --model, --append-system-prompt).
"""
import json, os, socket, sys, termios, time, tty

args = sys.argv[1:]


def arg(name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None


def out(s):
    sys.stdout.write(s.replace("\n", "\r\n"))
    sys.stdout.flush()


sock = None


def send(m):
    if sock is None:
        return
    m.setdefault("v", 1)
    try:
        sock.sendall((json.dumps(m) + "\n").encode())
    except OSError:
        pass


def status(agent, waiting=False):
    send({"id": "st", "type": "pi.status", "agent": agent, "waiting": waiting, "blockers": []})


if os.environ.get("DECKHAND_SOCKET") and os.environ.get("DECKHAND_TOKEN"):
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(os.environ["DECKHAND_SOCKET"])
    send({"id": "h", "type": "hello", "token": os.environ["DECKHAND_TOKEN"]})
    sid = arg("--session-id") or os.path.basename(arg("--session") or "x").split("_")[-1].replace(".jsonl", "")
    send({"id": "s", "type": "pi.session", "pi_session_id": sid, "session_file": "", "cwd": os.getcwd()})

prompt = arg("--append-system-prompt")
first = ""
if prompt and os.path.isfile(prompt):
    with open(prompt) as f:
        first = f.readline().strip()
out("\x1b[2J\x1b[H\x1b[1mpi\x1b[0m  fake Atlas\n")
out("model: %s\n" % (arg("--model") or "(pi's default)"))
out("prompt: %s\n" % (first or "(none)"))
out("control token: %s\n" % ("yes" if os.environ.get("DECKHAND_CONTROL_TOKEN") else "no"))
# Deckhand's pi integration: the -e paths it got (first in argv, each an extension folder with
# an index.ts), and which bridge variables it got (DECKHAND_*, never pi-kit's PI_DESK_*)
ext, i = [], 0
while i + 1 < len(args) and args[i] == "-e":
    ext.append(os.path.basename(args[i + 1]) if os.path.isfile(os.path.join(args[i + 1], "index.ts")) else "MISSING:" + args[i + 1])
    i += 2
out("integration: %s\n" % (" ".join(ext) or "none"))
BRIDGE = ["SOCKET", "TOKEN", "CONTROL_TOKEN", "SHOTS_DIR"]  # short lines: the drawer is narrow
# counts (the drawer is narrow): DECKHAND_SOCKET, _TOKEN, _CONTROL_TOKEN, _SHOTS_DIR; PI_DESK_ the same
out("deckhand env: %d of 4\n" % sum(1 for k in BRIDGE if os.environ.get("DECKHAND_" + k)))
out("pi-desk env: %d\n\n> " % sum(1 for k in BRIDGE if os.environ.get("PI_DESK_" + k)))
out("\x1b[?2004h")  # bracketed paste, as pi's editor asks for it
status("idle")

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
line = ""
asking = False
try:
    while True:
        c = os.read(fd, 1)
        if not c:
            break
        ch = c.decode("latin-1")
        if ch == "\x1b":
            seq = os.read(fd, 5).decode("latin-1")
            if seq == "[200~":
                buf = b""
                while not buf.endswith(b"\x1b[201~"):
                    more = os.read(fd, 1)
                    if not more:
                        break
                    buf += more
                text = buf[: -len(b"\x1b[201~")].decode("utf-8", "replace")
                lines = text.rstrip("\n").split("\n")
                out("\n[pasted %d lines]\n%s\n> " % (len(lines), "\n".join(lines)))
            continue
        if ch == "\x0c":
            out("\n[model selector] anthropic/claude-x  opencode-go/deepseek-v4.1-flash  opencode-go/muse-spark-1.2-contributor\n> ")
        elif ch in "\r\n":
            text, line = line, ""
            if asking:
                asking = False
                out("\nanswered: %s\n> " % text)
                status("idle")
            elif text == "go":
                status("working")
                out("\nworking…\n")
                time.sleep(1.0)
                out("Done: two projects are open.\n> ")
                status("idle")
            elif text == "ask":
                asking = True
                out("\n[dialog] Which branch? ")
                status("idle", waiting=True)
            else:
                out("\nyou: %s\n> " % text)
        elif ch == "\x7f":
            if line:
                line = line[:-1]
                out("\b \b")
        elif ch >= " ":
            line += ch
            out(ch)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
