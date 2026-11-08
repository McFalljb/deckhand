#!/usr/bin/env python3
"""A fake agent that reports its status over OSC 7501 (the program status
protocol), for tests/scripts/agent-status.sh. Never a real agent.

Usage: fake-7501.py [TAG]  (TAG follows HANDSHAKE-OK, to tell runs apart)

It asks the terminal first (OSC 7501 ; ?) and prints what came back, as
Claude Code does before it reports. Then it reads one word per line from
the keyboard and sends reports:

  work | block | done | idle | error     the root record (app=fake-agent)
  nest      root working, sub/1 blocked (question), sub/2 working
  clearsub  clear sub (takes sub/1 and sub/2)
  clear     clear everything
  bad       malformed reports: an unknown state, bad base64, a bad kind,
            a 64 KiB message, control and bidi characters, a bad id
  long      blocked with a 2000-byte message (kept: 256 bytes)
  flood     300 records (Deckhand keeps 256)
  prompt    OSC 133 A, as a shell's new prompt would
  exit      exit (the shell takes the foreground back)
"""
import base64
import os
import select
import sys
import termios
import tty

ESC = "\x1b"
ST = ESC + "\\"


def out(s):
    b = s.encode()
    while b:  # a pty may take a long report in pieces
        n = os.write(1, b)
        b = b[n:]


def b64(s):
    return base64.b64encode(s.encode()).decode()


def report(fields):
    out(ESC + "]7501;" + fields + "\x07")


def handshake(fd):
    """Asks; returns the reply's body (after '7501;'), or None."""
    out(ESC + "]7501;?" + ST)
    buf = b""
    while True:
        r, _, _ = select.select([fd], [], [], 3.0)
        if not r:
            return None
        buf += os.read(fd, 256)
        for end in (ST.encode(), b"\x07"):
            i = buf.find(end)
            if i >= 0:
                body = buf[:i].decode(errors="replace")
                j = body.find("7501;")
                return body[j + 5:] if j >= 0 else body


def main():
    fd = 0
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    try:
        reply = handshake(fd)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    tag = sys.argv[1] if len(sys.argv) > 1 else ""  # tells two runs apart on screen
    if reply is None:
        out("HANDSHAKE-NONE" + tag + "\r\n")
    else:
        out("HANDSHAKE-OK" + tag + " " + reply.replace(ESC, "^[") + "\r\n")
    app = "app=fake-agent"
    for line in sys.stdin:
        w = line.strip()
        if w == "work":
            report("state=working:" + app + ":msg=" + b64("Thinking"))
        elif w == "block":
            report("state=blocked:kind=permission:" + app + ":msg=" + b64("Edit main.odin?"))
        elif w == "done":
            report("state=done:" + app + ":msg=" + b64("All tests pass"))
        elif w == "idle":
            report("state=idle:" + app)
        elif w == "error":
            report("state=error:id=e:" + app + ":msg=" + b64("Build failed"))
        elif w == "nest":
            report("state=working:" + app)
            report("state=blocked:id=sub/1:kind=question:title=" + b64("Sub one") + ":msg=" + b64("Which branch?"))
            report("state=working:id=sub/2")
        elif w == "clearsub":
            report("state=clear:id=sub")
        elif w == "clear":
            report("state=clear")
        elif w == "bad":
            report("state=sleeping:" + app)  # unknown state: dropped
            report("state=blocked:kind=telepathy:" + app)  # unknown kind: blocked, kind none
            report("state=done:id=badmsg:msg=!!!not base64!!!")  # the message is dropped
            report("state=working:id=big:msg=" + b64("A" * 65536))  # 64 KiB: cut (or dropped)
            report("state=done:id=spoof:msg=" + b64("ok‮gnp.exe​\x07\x1b[31mred"))
            report("state=done:id=" + "x" * 600)
        elif w == "long":
            report("state=blocked:" + app + ":msg=" + b64("B" * 2000))  # valid: Deckhand keeps 256 bytes
        elif w == "flood":
            for i in range(300):
                report("state=done:id=flood/%d" % i)
        elif w == "prompt":
            out(ESC + "]133;A" + ST)
        elif w == "exit":
            out("BYE\r\n")
            return
        else:
            continue
        out("ok:" + w + "\r\n")


if __name__ == "__main__":
    main()
