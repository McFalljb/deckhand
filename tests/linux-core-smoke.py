#!/usr/bin/env python3
"""The Linux core runs (docs/plans/background-core.md §10.4 M6-L1; CI's linux job): starts
`deckhand-core-serve serve` in test mode in a temp dir, reads the control token it prints, says
hello on core.sock, asks get_state and add_project, then stops it with SIGTERM and expects a clean
exit. Test mode only (fake HOME, its own data and runtime dir); no pi, no network.

Usage: tests/linux-core-smoke.py [build/deckhand-core-serve]
"""
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "build/deckhand-core-serve")


def main():
    d = tempfile.mkdtemp(prefix="dh-smoke-")
    data, run, home = f"{d}/data", f"{d}/run", f"{d}/home"
    os.makedirs(home)
    env = dict(os.environ, HOME=home, DECKHAND_SCRIPT="smoke", DECKHAND_DATA_DIR=data, DECKHAND_RUNTIME_DIR=run)
    p = subprocess.Popen([BIN, "serve", "--run", run, "--data", data], env=env, stdout=subprocess.PIPE, text=True)
    try:
        sock_path = token = None
        deadline = time.time() + 15
        while time.time() < deadline and not token:
            line = p.stdout.readline()
            if not line:
                break
            m = re.match(r"export DECKHAND_SOCKET='([^']+)' DECKHAND_TOKEN='([^']+)'", line)
            if m:
                sock_path, token = m.groups()
        assert token, "the core printed no control token"
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(10)
        s.connect(sock_path)
        f = s.makefile("rw")

        def ask(msg):
            f.write(json.dumps(msg) + "\n")
            f.flush()
            while True:
                r = json.loads(f.readline())
                if r.get("id") == msg["id"]:
                    return r

        r = ask({"id": "h", "v": 1, "type": "hello", "token": token})
        assert r["result"]["ok"], r
        r = ask({"id": "s", "v": 1, "type": "command", "command": {"type": "get_state"}})
        assert r["result"]["ok"], r
        r = ask({"id": "p", "v": 1, "type": "command", "command": {"type": "add_project", "cwd": home}})
        assert r["result"]["ok"], r
        s.close()
        p.send_signal(signal.SIGTERM)
        code = p.wait(timeout=15)
        assert code == 0, f"exit {code}"
        print("linux-core-smoke: ok (hello, get_state, add_project, SIGTERM)")
    finally:
        if p.poll() is None:
            p.kill()


if __name__ == "__main__":
    main()
