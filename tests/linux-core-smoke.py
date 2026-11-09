#!/usr/bin/env python3
"""The Linux core runs (docs/plans/background-core.md §10.4 M6-L1; CI's linux job): starts
`deckhand-core-serve serve` in test mode in a temp dir, reads the control token it prints, says
hello on core.sock, asks get_state, opens a project, a session (a stand-in for pi) and a shell tab
whose shell writes a file (a PTY end to end), then stops it with SIGTERM and expects a clean exit.
Test mode only (fake HOME); no pi, no network.

--default-dirs: the default data and runtime dirs under the fake HOME (Linux:
~/.local/share/deckhand, sockets in ~/.local/state/deckhand/run), not DECKHAND_DATA_DIR and
DECKHAND_RUNTIME_DIR.

Usage: tests/linux-core-smoke.py [--default-dirs] [build/deckhand-core-serve]
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

ARGS = [a for a in sys.argv[1:] if a != "--default-dirs"]
DEFAULT_DIRS = "--default-dirs" in sys.argv[1:]
BIN = os.path.abspath(ARGS[0] if ARGS else "build/deckhand-core-serve")


def main():
    d = tempfile.mkdtemp(prefix="dh-smoke-")
    home = f"{d}/home"
    os.makedirs(home)
    # pi's stand-in: the session's first tab runs it
    env = dict(os.environ, HOME=home, DECKHAND_SCRIPT="smoke", DECKHAND_CMD="sleep 60")
    if DEFAULT_DIRS:
        data, run = f"{home}/.local/share/deckhand", f"{home}/.local/state/deckhand/run"
    else:
        data, run = f"{d}/data", f"{d}/run"
        env.update(DECKHAND_DATA_DIR=data, DECKHAND_RUNTIME_DIR=run)
    os.makedirs(data, mode=0o700)
    os.makedirs(run, mode=0o700)  # the launcher makes it (sock_runtime_dir): serve expects it
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
        assert sock_path == f"{run}/core.sock", sock_path
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
        r = ask({"id": "n", "v": 1, "type": "command", "command": {"type": "new_chat", "project_id": r["result"]["created_id"]}})
        assert r["result"]["ok"], r
        r = ask({"id": "t", "v": 1, "type": "command", "command": {"type": "new_shell_tab", "session": r["result"]["created_id"]}})
        assert r["result"]["ok"], r
        mark = f"{home}/pty-ok"
        r = ask({"id": "x", "v": 1, "type": "command", "command": {"type": "send_text", "tab_id": r["result"]["created_id"], "text": f"echo ok > {mark}\r"}})
        assert r["result"]["ok"], r
        deadline = time.time() + 15
        while time.time() < deadline and not os.path.exists(mark):
            time.sleep(0.1)
        assert os.path.exists(mark), "the shell tab's shell did not run the command"
        s.close()
        p.send_signal(signal.SIGTERM)
        code = p.wait(timeout=15)
        assert code == 0, f"exit {code}"
        print(f"linux-core-smoke: ok (sockets in {run}; hello, get_state, a shell tab ran a command, SIGTERM)")
    finally:
        if p.poll() is None:
            p.kill()


if __name__ == "__main__":
    main()
