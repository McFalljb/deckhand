# A fake pi-kit bridge that publishes the largest panel set a bridge may send
# (16 panels x 200 rows x 512-byte rows, far past pi-desk's caps) and stays
# connected with pi working, so the status dot pulses. For tests/scripts/panels-cpu.txt.
import json, os, socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(os.environ["PI_DESK_SOCKET"])
def send(m):
    m.setdefault("v", 1)
    s.sendall((json.dumps(m) + "\n").encode())
send({"id": "h", "type": "hello", "token": os.environ["PI_DESK_TOKEN"]})
send({"id": "s", "type": "pi.status", "agent": "working", "waiting": False, "blockers": []})
row = ("● worker step " + "x" * 600)[:512]
for p in range(16):
    rows = [{"text": f"Panel {p}", "head": True}] + [{"text": f"{i} {row}", "tone": "accent" if i % 3 == 0 else "muted"} for i in range(199)]
    send({"id": f"p{p}", "type": "panel.set", "panel": f"panel{p}", "title": f"Panel {p}", "rows": rows})
print("\x1b[2J\x1b[Hpi  fake max bridge", flush=True)
while s.recv(65536):
    pass
