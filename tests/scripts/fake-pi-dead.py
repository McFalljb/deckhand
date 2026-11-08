#!/usr/bin/env python3
"""A fake pi that dies, for tests/scripts/dead-tab.sh (Deckhand's dead-tab bar).

It plays pi's terminal UI just enough and the pi integration's bridge over Deckhand's
socket (DECKHAND_SOCKET, DECKHAND_TOKEN): hello, pi.session, pi.status idle. It
prints its arguments (--session, --model). Keys (the terminal is raw):
  Ctrl+L        "[model selector]" (pi's app.model.select)
  a line "limit"  a provider's rate-limit error, then exits with code 1
  a line "quit"   exits with code 0 (/quit)
  a line "hup"    kills itself with SIGHUP (as a mass hangup would)
Never calls a model: nothing here talks to anything but Deckhand's socket.
"""
import json, os, signal, socket, sys, termios, tty

args = sys.argv[1:]


def arg(name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None


def out(s):
    sys.stdout.write(s.replace("\n", "\r\n"))
    sys.stdout.flush()


sock = None
if os.environ.get("DECKHAND_SOCKET") and os.environ.get("DECKHAND_TOKEN"):
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(os.environ["DECKHAND_SOCKET"])

    def send(m):
        m.setdefault("v", 1)
        sock.sendall((json.dumps(m) + "\n").encode())

    send({"id": "h", "type": "hello", "token": os.environ["DECKHAND_TOKEN"]})
    sid = arg("--session-id") or os.path.basename(arg("--session") or "x").split("_")[-1].replace(".jsonl", "")
    send({"id": "s", "type": "pi.session", "pi_session_id": sid, "session_file": arg("--session") or "", "cwd": os.getcwd()})
    send({"id": "st", "type": "pi.status", "agent": "idle", "waiting": False, "blockers": []})

out("\x1b[1mpi\x1b[0m  fake pi (dies)\n")
out("session: %s\n" % os.path.basename(arg("--session") or arg("--session-id") or "-"))
out("model: %s\n\n> " % (arg("--model") or "(the session's)"))
out("\x1b[?2004h")

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
line = ""
try:
    while True:
        c = os.read(fd, 1)
        if not c:
            break
        ch = c.decode("latin-1")
        if ch == "\x0c":
            out("\n[model selector] anthropic/claude-x  opencode-go/deepseek-v4.1-flash\n> ")
        elif ch in "\r\n":
            text, line = line, ""
            if text == "limit":
                out("\nError: 429 rate_limit_error: You have hit your usage limit.\n")
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
                sys.exit(1)
            elif text == "quit":
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
                sys.exit(0)
            elif text == "hup":
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
                os.kill(os.getpid(), signal.SIGHUP)
            else:
                out("\nyou: %s\n> " % text)
        elif ch >= " ":
            line += ch
            out(ch)
finally:
    try:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    except termios.error:
        pass
