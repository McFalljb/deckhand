# A fake pi-integration bridge for tests/scripts/persist-cpu.sh: reports pi.status
# and a todos panel once a second, as a working agent does.
import json, os, socket, time
s = socket.socket(socket.AF_UNIX)
s.connect(os.environ["DECKHAND_SOCKET"])
def send(m):
    m.setdefault("v", 1)
    s.sendall((json.dumps(m) + "\n").encode())
send({"id": "h", "type": "hello", "token": os.environ["DECKHAND_TOKEN"]})
print("\x1b[2J\x1b[Hpi  fake status bridge", flush=True)
s.setblocking(False)
i = 0
while True:
    i += 1
    send({"id": f"s{i}", "type": "pi.status", "agent": "working" if i % 2 else "idle", "waiting": False, "blockers": []})
    send({"id": f"p{i}", "type": "panel.set", "panel": "todos", "title": "Todos", "rows": [{"text": f"step {i}"}]})
    time.sleep(1)
    try:
        while s.recv(65536):
            pass
    except BlockingIOError:
        pass
