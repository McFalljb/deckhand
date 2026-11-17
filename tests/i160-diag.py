#!/usr/bin/env python3
"""TEMPORARY (#160 diagnosis, removed before merge): why a fresh held shell tab answers send_text
with "a program is running". Opens many shell tabs and types into each at once; on a refusal,
prints what holds the terminal's foreground."""
import importlib.util
import os
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location("smoke", os.path.join(os.path.dirname(__file__), "linux-holder-smoke.py"))
smoke = importlib.util.module_from_spec(spec)
sys.argv = [sys.argv[0]] + sys.argv[1:]
spec.loader.exec_module(smoke)


def tab_pid(link, tab):
    st = link.ok({"type": "get_state"})["data"]
    for s in st.get("open_sessions", []):
        for t in s["tabs"]:
            if t.get("id") == tab:
                return t.get("pid")
    return None


def main():
    n = int(os.environ.get("DIAG_N", "40"))
    print("== /etc/profile.d:", sorted(os.listdir("/etc/profile.d")))
    dirs = smoke.Dirs()
    core = smoke.Core(dirs)
    busy = 0
    try:
        link = smoke.Link(*smoke.wait_for("control token", lambda: smoke.token_in(core.text())))
        smoke.open_shell(link, dirs.home)
        st = link.ok({"type": "get_state"})["data"]
        session = st["open_sessions"][0]["id"]
        for i in range(n):
            tab = link.ok({"type": "new_shell_tab", "session": session})["created_id"]
            t0 = time.time()
            r = None
            for _ in range(50):
                r = link.ask({"type": "send_text", "tab_id": tab, "text": "true\r"})
                if r["result"]["ok"] or "not known yet" not in r["result"].get("error", ""):
                    break
            dt = time.time() - t0
            if r["result"]["ok"]:
                print(f"tab {tab}: ok after {dt*1000:.0f} ms")
                continue
            busy += 1
            pid = tab_pid(link, tab)
            ps = subprocess.run(["ps", "-o", "pid,ppid,pgid,sid,tpgid,stat,etimes,args", "-g", str(pid)], capture_output=True, text=True).stdout
            ps2 = subprocess.run(["ps", "-e", "-o", "pid,ppid,pgid,sid,tpgid,stat,args"], capture_output=True, text=True).stdout
            sess = [l for l in ps2.splitlines() if l.split()[3:4] == [str(pid)]]
            print(f"tab {tab}: REFUSED after {dt*1000:.0f} ms: {r['result'].get('error')}\n  shell pid {pid}\n" + "\n".join("  " + l for l in sess))
        print(f"== {busy}/{n} refused")
    finally:
        core.p.kill()
        subprocess.run(["pkill", "-9", "-f", f"deckhand-core-serve serve --run {dirs.run}"])
        dirs.cleanup()


main()
