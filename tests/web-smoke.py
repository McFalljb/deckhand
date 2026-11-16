#!/usr/bin/env python3
"""Web access end to end (docs/PROTOCOL.md §5c): starts `deckhand-core-serve serve` in test mode in a
temp dir with web access on, listening on 127.0.0.1 at a free port, then: the page and its headers,
whoami (401), a code from `deckhand-core-serve web pair`, /api/pair (wrong origin, wrong code, the
right one), whoami (200), the WebSocket upgrade (refused without Origin or cookie), the hello,
state.subscribe -> state.full, a command, a User_Here command refused, `web list` showing the link,
a text message closing it, `web revoke`, then SIGTERM. Test mode only (fake HOME); no network beyond
127.0.0.1.

Usage: tests/web-smoke.py [build/deckhand-core-serve]
"""
import base64
import json
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "build/deckhand-core-serve")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def http(port, method, path, headers=None, body=b""):
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    h = {"Host": f"127.0.0.1:{port}"}
    h.update(headers or {})
    if method == "POST":
        h["Content-Length"] = str(len(body))
    req = f"{method} {path} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in h.items()) + "\r\n"
    s.sendall(req.encode() + body)
    data = b""
    while True:
        c = s.recv(65536)
        if not c:
            break
        data += c
    s.close()
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    status = int(lines[0].split()[1])
    hdrs = {}
    for l in lines[1:]:
        k, _, v = l.partition(":")
        hdrs.setdefault(k.strip().lower(), []).append(v.strip())
    return status, hdrs, rest


class WS:
    def __init__(self, port, cookie, origin=True):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        h = f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
        if origin:
            h += f"Origin: http://127.0.0.1:{port}\r\n"
        if cookie:
            h += f"Cookie: {cookie}\r\n"
        self.s.sendall((h + "\r\n").encode())
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            c = self.s.recv(4096)
            if not c:
                break
            self.buf += c
        head, _, self.buf = self.buf.partition(b"\r\n\r\n")
        self.status = int(head.split(b" ")[1]) if head else 0

    def send(self, op, payload):
        mask = os.urandom(4)
        n = len(payload)
        h = bytes([0x80 | op])
        if n < 126:
            h += bytes([0x80 | n])
        elif n < 65536:
            h += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            h += bytes([0x80 | 127]) + struct.pack(">Q", n)
        self.s.sendall(h + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(payload)))

    def send_json(self, obj):
        p = json.dumps(obj).encode()
        self.send(2, struct.pack("<IBI", 0, 1, len(p)) + p)

    def _need(self, n):
        while len(self.buf) < n:
            c = self.s.recv(65536)
            if not c:
                raise EOFError
            self.buf += c

    def recv(self):
        self._need(2)
        op, n = self.buf[0] & 0x0F, self.buf[1] & 0x7F
        at = 2
        if n == 126:
            self._need(4)
            n, at = struct.unpack(">H", self.buf[2:4])[0], 4
        elif n == 127:
            self._need(10)
            n, at = struct.unpack(">Q", self.buf[2:10])[0], 10
        self._need(at + n)
        p, self.buf = self.buf[at:at + n], self.buf[at + n:]
        return op, p

    def recv_json(self, want=None, limit=200):
        for _ in range(limit):
            op, p = self.recv()
            if op == 8:
                raise EOFError("closed")
            if op != 2:
                continue
            ch, kind, ln = struct.unpack("<IBI", p[:9])
            assert len(p) == 9 + ln, "one frame per message"
            if ch != 0:
                continue
            m = json.loads(p[9:])
            if want is None or want(m):
                return m
        raise AssertionError("no such message")


def cli(env, *args):
    r = subprocess.run([BIN, "web", *args], env=env, capture_output=True, text=True, timeout=30)
    return r.returncode, r.stdout + r.stderr


def main():
    d = tempfile.mkdtemp(prefix="dh-web-")
    home, data, run = f"{d}/home", f"{d}/data", f"{d}/run"
    os.makedirs(home)
    os.makedirs(data, mode=0o700)
    os.makedirs(run, mode=0o700)
    port = free_port()
    with open(f"{data}/workspace.json", "w") as f:
        json.dump({"v": 1, "settings": {"web_access": True, "web_listen": f"127.0.0.1:{port}", "setup_seen": True}}, f)
    env = {"HOME": home, "PATH": "/usr/bin:/bin", "DECKHAND_SCRIPT": "smoke", "DECKHAND_CMD": "sleep 60", "DECKHAND_DATA_DIR": data, "DECKHAND_RUNTIME_DIR": run}
    p = subprocess.Popen([BIN, "serve", "--run", run, "--data", data], env=env, stdout=subprocess.PIPE, stderr=open(f"{d}/core.err", "w"), text=True)
    ok = False
    try:
        deadline = time.time() + 15
        while time.time() < deadline:
            line = p.stdout.readline()
            if not line or line.startswith("export DECKHAND_SOCKET"):
                break
        for _ in range(100):  # the loop's first turn starts the listener
            try:
                st, h, body = http(port, "GET", "/")
                break
            except OSError:
                time.sleep(0.1)
        assert st == 200 and b"<html" in body.lower(), (st, body[:200])
        csp = h["content-security-policy"][0]
        assert "default-src 'self'" in csp and "frame-ancestors 'none'" in csp and "unsafe-eval" not in csp, csp
        assert h["x-content-type-options"] == ["nosniff"] and h["referrer-policy"] == ["no-referrer"], h
        assert "access-control-allow-origin" not in h
        assert http(port, "GET", "/nope")[0] == 404
        assert http(port, "GET", "/assets/../web.odin")[0] == 404
        assert http(port, "DELETE", "/")[0] == 405
        st, h, body = http(port, "GET", "/api/whoami")
        assert st == 401 and json.loads(body) == {"paired": False}, (st, body)
        rc, out = cli(env, "pair")
        assert rc == 0, out
        code = re.search(r"code: ([A-Z0-9]{4}-[A-Z0-9]{4})", out).group(1)
        origin = {"Origin": f"http://127.0.0.1:{port}"}
        assert http(port, "POST", "/api/pair", {"Origin": "http://evil.example"}, json.dumps({"code": code, "name": "t"}).encode())[0] == 403
        assert http(port, "POST", "/api/pair", origin, json.dumps({"code": "AAAA-AAAA", "name": "t"}).encode())[0] == 403
        st, h, body = http(port, "POST", "/api/pair", origin, json.dumps({"code": code.lower(), "name": "Smoke browser"}).encode())
        assert st == 200, (st, body)
        sc = h["set-cookie"][0]
        assert "HttpOnly" in sc and "SameSite=Strict" in sc and "Max-Age=5184000" in sc, sc
        cookie = sc.split(";")[0]
        assert re.fullmatch(r"deckhand_web=[0-9a-f]{64}", cookie), cookie
        assert http(port, "POST", "/api/pair", origin, json.dumps({"code": code, "name": "again"}).encode())[0] == 403, "single use"
        st, h, body = http(port, "GET", "/api/whoami", {"Cookie": cookie})
        w = json.loads(body)
        assert st == 200 and w["paired"] and w["name"] == "Smoke browser" and len(w["core"]) == 64, body
        assert WS(port, cookie, origin=False).status == 403
        assert WS(port, "").status == 401
        ws = WS(port, cookie)
        assert ws.status == 101, ws.status
        ws.send_json({"v": 1, "id": "hello", "type": "hello", "framed": True, "peer": "web", "snapshot": ["vt"]})
        m = ws.recv_json(lambda m: m.get("type") == "result" and m.get("id") == "hello")
        hd = m["result"]["data"]
        assert m["result"]["ok"] and hd["core"] == w["core"] and hd["snapshot"] == ["vt"], m
        assert "new_chat" in hd["methods"] and "set_web_access" not in hd["methods"] and "show_no_session" in hd["methods"] and "copy_control_token" not in hd["methods"], hd["methods"]
        ws.send_json({"v": 1, "type": "state.subscribe"})
        m = ws.recv_json(lambda m: m.get("type") == "state.full")
        assert m["state"]["settings"]["settings"]["web_access"] is True, m["state"]["settings"]
        ws.send_json({"v": 1, "type": "command", "id": "c1", "now": True, "command": {"type": "add_project", "cwd": home}})
        m = ws.recv_json(lambda m: m.get("type") == "result" and m.get("id") == "c1")
        assert m["result"]["ok"], m
        ws.send_json({"v": 1, "type": "command", "id": "c2", "now": True, "command": {"type": "set_web_access", "on": False}})
        m = ws.recv_json(lambda m: m.get("type") == "result" and m.get("id") == "c2")
        assert m["result"]["error"] == "not allowed for this caller", m
        ws.send_json({"v": 1, "type": "window.command", "id": "c3", "now": True, "command": {"holder_restart": {}}})
        m = ws.recv_json(lambda m: m.get("type") == "result" and m.get("id") == "c3")
        assert not m["result"]["ok"], m
        rc, out = cli(env, "list")
        assert rc == 0 and "Smoke browser" in out and "viewing now" in out, out
        dev = out.split()[0]
        ws.send(1, b"text")  # a text message: the link closes
        try:
            ws.recv_json(limit=50)
            closed = False
        except EOFError:
            closed = True
        assert closed, "a text message closes the link"
        rc, out = cli(env, "revoke", dev)
        assert rc == 0, out
        assert http(port, "GET", "/api/whoami", {"Cookie": cookie})[0] == 401
        rc, out = cli(env, "off")
        assert rc == 0, out
        ok = True
        print("web-smoke: ok")
    finally:
        p.terminate()
        try:
            p.wait(15)
        except subprocess.TimeoutExpired:
            p.kill()
        if not ok:
            print(open(f"{d}/core.err").read()[-4000:])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
