#!/usr/bin/env python3
"""Sessions outlive the Linux core (docs/plans/background-core.md §10.4 M6-L3; CI's linux job).
`deckhand-core-serve serve` in test mode, with keep_sessions on (seeded in workspace.json), so
its tabs run in the session holder (build/deckhand-core beside it). A shell tab writes its pid
($$) to a file, then:

1. SIGTERM: the core hands over (snapshots). Started again, it adopts every terminal exactly
   (the same screen hash as at the handover) and the shell is the same process.
2. kill -9: the holder's supervisor relaunches the core (`deckhand-core-serve launch`, its output
   in <run>/core.log), which adopts from the holder's tails (inexact, "previous crash"); the
   shell is still the same process.

--systemd (CI, after tests/linux-systemd-check.sh --real turned linger on; XDG_RUNTIME_DIR set):
the core runs as a transient service (`systemd-run --user`, KillMode=control-group, systemd's
default) with DECKHAND_HOLDER_SYSTEMD=1, so the holder starts in a scope of its own
(deckhand-holder-*.scope). `systemctl --user stop` of the core's service kills everything in its
cgroup; the shell, in the holder's scope, must live on.

A fake HOME and temp dirs; no pi, no network. Usage:
  tests/linux-holder-smoke.py [--systemd] [build/deckhand-core-serve]
"""
import json
import os
import re
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

ARGS = [a for a in sys.argv[1:] if a != "--systemd"]
SYSTEMD = "--systemd" in sys.argv[1:]
BIN = os.path.abspath(ARGS[0] if ARGS else "build/deckhand-core-serve")
HOLDER = os.path.join(os.path.dirname(BIN), "deckhand-core")
TOKEN_RE = re.compile(r"export DECKHAND_SOCKET='([^']+)' DECKHAND_TOKEN='([^']+)'")


def fail(msg):
    sys.exit(f"linux-holder-smoke: {msg}")


def wait_for(what, pred, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = pred()
        if v:
            return v
        time.sleep(0.1)
    fail(f"no {what} in {timeout} s")


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # a zombie is not running
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def cgroup(pid):
    try:
        with open(f"/proc/{pid}/cgroup") as f:
            return f.read().strip()
    except OSError:
        return ""


class Dirs:
    def __init__(self):
        self.d = tempfile.mkdtemp(prefix="dh-hold-")
        self.home = f"{self.d}/home"
        self.data = f"{self.d}/data"
        self.run = f"{self.d}/run"
        for p in (self.home, self.data, self.run):
            os.makedirs(p, mode=0o700)
        # keep_sessions on: test mode's default is off (commands.odin keep_sessions_default)
        with open(f"{self.data}/workspace.json", "w") as f:
            json.dump({"v": 1, "settings": {"keep_sessions": True}}, f)
        self.env = {
            "HOME": self.home,
            "SHELL": "/bin/sh",
            "DECKHAND_SCRIPT": "smoke",
            "DECKHAND_CMD": "sleep 600",  # pi's stand-in: the session's first tab runs it
            "DECKHAND_DATA_DIR": self.data,
            "DECKHAND_RUNTIME_DIR": self.run,
        }

    def holders(self):
        out = subprocess.run(["pgrep", "-f", f"deckhand-core hold --run {self.run}"], capture_output=True, text=True).stdout
        return [int(p) for p in out.split()]

    def cleanup(self, *pids):
        for p in list(pids) + self.holders():
            try:
                os.kill(p, signal.SIGKILL)
            except (ProcessLookupError, TypeError):
                pass


class Core:
    """A serve started here (Popen), its stdout collected by a thread."""

    def __init__(self, dirs):
        self.lines = []
        self.p = subprocess.Popen([BIN, "serve", "--run", dirs.run, "--data", dirs.data],
                                  env=dict(os.environ, **dirs.env), stdout=subprocess.PIPE, text=True)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            self.lines.append(line)

    def text(self):
        return "".join(self.lines)


class Link:
    def __init__(self, sock_path, token):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(10)
        self.s.connect(sock_path)
        self.f = self.s.makefile("rw")
        self.n = 0
        r = self.ask({"type": "hello", "token": token}, raw=True)
        if not r["result"]["ok"]:
            fail(f"hello: {r}")

    def ask(self, msg, raw=False):
        self.n += 1
        mid = f"m{self.n}"
        full = dict(msg, id=mid, v=1) if raw else {"id": mid, "v": 1, "type": "command", "command": msg}
        self.f.write(json.dumps(full) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if r.get("id") == mid:
                return r

    def ok(self, msg):
        r = self.ask(msg)
        if not r["result"]["ok"]:
            fail(f"{msg['type']}: {r}")
        return r["result"]

    def close(self):
        self.s.close()


def token_in(text):
    m = None
    for m in TOKEN_RE.finditer(text):
        pass
    return m.groups() if m else None


def open_shell(link, home):
    """A project, a session and a shell tab whose shell writes its pid: (tab id, shell pid)."""
    pid_file = f"{home}/shell-pid"
    project = link.ok({"type": "add_project", "cwd": home})["created_id"]
    session = link.ok({"type": "new_chat", "project_id": project})["created_id"]
    tab = link.ok({"type": "new_shell_tab", "session": session})["created_id"]
    link.ok({"type": "send_text", "tab_id": tab, "text": f"echo $$ > {pid_file}.tmp && mv {pid_file}.tmp {pid_file}\r"})
    pid = int(wait_for("shell pid file", lambda: os.path.exists(pid_file) and open(pid_file).read().strip()))
    return tab, pid


def shell_tab(link):
    """The one shell tab, as get_state shows it."""
    st = link.ok({"type": "get_state"})["data"]
    tabs = [t for s in st.get("open_sessions", []) for t in s["tabs"] if t.get("kind") == "shell"]
    if len(tabs) != 1:
        fail(f"{len(tabs)} shell tabs in get_state, want 1: {st.get('open_sessions')}")
    return tabs[0]


def survive_restarts():
    dirs = Dirs()
    core = Core(dirs)
    shell = None
    try:
        sock_path, token = wait_for("control token", lambda: token_in(core.text()))
        link = Link(sock_path, token)
        _, shell = open_shell(link, dirs.home)
        t = shell_tab(link)
        if not t.get("held"):
            fail(f"the shell tab is not held by the session holder: {t}")
        holders = dirs.holders()
        if len(holders) != 1:
            fail(f"{len(holders)} session holders run, want 1")
        if os.readlink(f"/proc/{holders[0]}/exe") != os.path.realpath(HOLDER):
            fail(f"the holder runs {os.readlink(f'/proc/{holders[0]}/exe')}")
        link.close()

        # 1. SIGTERM: a handover; started again, adopted exactly, the same shell
        core.p.send_signal(signal.SIGTERM)
        code = core.p.wait(timeout=20)
        if code != 0:
            fail(f"SIGTERM: exit {code}")
        handed = dict(re.findall(r"\[autotest\] handover (\d+) offset \d+ hash (\w+)", core.text()))
        held = str(t["held"])
        if held not in handed:
            fail(f"the shell's terminal {held} was not handed over ({handed}):\n{core.text()}")
        if not alive(shell):
            fail("the shell died with the core (SIGTERM)")
        core = Core(dirs)
        wait_for("adoption", lambda: len(re.findall(r"\[autotest\] adopted \d+", core.text())) >= len(handed))
        adopted = {m[0]: (m[1], m[2]) for m in re.findall(r"\[autotest\] adopted (\d+) hash (\w+) (exact|inexact)", core.text())}
        for term, h in handed.items():
            if adopted.get(term) != (h, "exact"):
                fail(f"terminal {term}: handover hash {h}, adopted {adopted.get(term)}")
        sock_path, token = wait_for("control token", lambda: token_in(core.text()))
        link = Link(sock_path, token)
        t = shell_tab(link)
        if t.get("pid") != shell or t.get("status") != "running" or t.get("inexact"):
            fail(f"after SIGTERM: the shell tab is {t}, want pid {shell}, running, exact")
        link.close()
        print(f"linux-holder-smoke: SIGTERM: {len(handed)} terminals adopted exactly, shell pid {shell} kept")

        # 2. kill -9: the holder's supervisor relaunches the core; adopted from the tails
        core.p.kill()
        core.p.wait(timeout=10)
        if not alive(shell):
            fail("the shell died with the core (kill -9)")
        log = f"{dirs.run}/core.log"

        def relaunched():
            try:
                text = open(log).read()
            except OSError:
                return None
            return text if len(re.findall(r"\[autotest\] adopted \d+", text)) >= len(handed) and token_in(text) else None

        text = wait_for("core relaunched by the holder's supervisor (core.log)", relaunched, timeout=30)
        adopted = re.findall(r"\[autotest\] adopted (\d+) hash \w+ (exact|inexact)", text)
        if any(x != "inexact" for _, x in adopted):
            fail(f"after kill -9: {adopted}, want every terminal inexact")
        if "holder attached: previous crash" not in text:
            fail(f"after kill -9 the holder did not say previous crash:\n{text}")
        link = Link(*token_in(text))
        t = shell_tab(link)
        if t.get("pid") != shell or t.get("status") != "running" or not t.get("inexact"):
            fail(f"after kill -9: the shell tab is {t}, want pid {shell}, running, inexact")
        link.close()
        if not alive(shell):
            fail("the shell is gone after the relaunch")
        print(f"linux-holder-smoke: kill -9: the supervisor relaunched the core, {len(adopted)} terminals adopted (inexact), shell pid {shell} kept")
    finally:
        if core.p.poll() is None:
            core.p.kill()
        subprocess.run(["pkill", "-9", "-f", f"deckhand-core-serve serve --run {dirs.run}"])
        dirs.cleanup(shell)


def survive_unit_stop():
    if not os.environ.get("XDG_RUNTIME_DIR"):
        fail("--systemd needs XDG_RUNTIME_DIR (the user manager's bus)")
    dirs = Dirs()
    unit = f"dh-hold-smoke-{secrets.token_hex(4)}"
    out = f"{dirs.d}/core.out"
    argv = ["systemd-run", "--user", "--quiet", "--collect", "--unit", unit,
            "-p", "KillMode=control-group", "-p", f"StandardOutput=file:{out}", "-p", f"StandardError=file:{dirs.d}/core.err"]
    for k, v in dict(dirs.env, DECKHAND_HOLDER_SYSTEMD="1").items():
        argv.append(f"--setenv={k}={v}")
    argv += ["--", BIN, "serve", "--run", dirs.run, "--data", dirs.data]
    subprocess.run(argv, check=True)
    shell = None
    holder_scope = ""
    try:
        def read_out():
            try:
                return open(out).read()
            except OSError:
                return ""

        link = Link(*wait_for("control token", lambda: token_in(read_out())))
        _, shell = open_shell(link, dirs.home)
        link.close()
        holders = dirs.holders()
        if len(holders) != 1:
            fail(f"{len(holders)} session holders run, want 1")
        hc = cgroup(holders[0])
        m = re.search(r"(deckhand-holder-[0-9a-f]{8}\.scope)", hc)
        if not m:
            fail(f"the holder is not in a scope of its own: {hc}")
        holder_scope = m.group(1)
        if f"{unit}.service" in hc:
            fail(f"the holder is in the core's service: {hc}")
        if holder_scope not in cgroup(shell):
            fail(f"the shell is not in the holder's scope: {cgroup(shell)}")
        subprocess.run(["systemctl", "--user", "stop", f"{unit}.service"], check=True)
        time.sleep(1)
        if not alive(shell):
            fail(f"systemctl --user stop {unit}.service killed the shell")
        if not dirs.holders():
            fail(f"systemctl --user stop {unit}.service killed the holder")
        print(f"linux-holder-smoke: systemd: the holder runs in {holder_scope}; systemctl --user stop of the core's service left shell pid {shell} running")
    finally:
        subprocess.run(["systemctl", "--user", "stop", f"{unit}.service"], capture_output=True)
        if holder_scope:
            subprocess.run(["systemctl", "--user", "stop", holder_scope], capture_output=True)
        dirs.cleanup(shell)


def main():
    if not os.path.isfile(HOLDER):
        fail(f"no session holder at {HOLDER} (odin build src/holder -out:{HOLDER})")
    if SYSTEMD:
        survive_unit_stop()
    else:
        survive_restarts()


if __name__ == "__main__":
    main()
