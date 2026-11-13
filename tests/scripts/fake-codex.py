#!/usr/bin/env python3
"""A fake `codex` for Deckhand's Codex-tab scenes (never the real one; no network, no ~/.codex).

Deckhand starts it in a Codex tab's PTY as
`fake-codex.py [resume ID] --no-daemon -C DIR -c hooks.<Event>=[…] … -c hooks.state={…}`
(src/core/codex.odin). It behaves like Codex 0.167.2 where Deckhand can see it:

- Checks the command line as Codex would read it and prints `FAKE CODEX ARGS OK` (else
  `FAKE CODEX ARGS BAD: <why>` and exit 3): --no-daemon present; -C an absolute folder; no -s, -a,
  -m, -p, `projects`, `notify` or --dangerously-bypass-hook-trust; mcp_servers only as Deckhand's own
  server (one inline table: an absolute command, args ["mcp"], env_vars, no env); every -c value is TOML
  (tomllib); every hook Deckhand passes has a trusted_hash in hooks.state that matches Codex
  0.167.2's recipe (the hash below). Each hook that matches is "trusted" (`FAKE CODEX TRUST OK n`);
  one that does not is "modified": it never runs and `HOOKS NEED REVIEW` is printed (Codex's dialog).
- `login status`: exit 1 with FAKE_CODEX_SIGNED_OUT=1 (signed out), else 0. Nothing is printed.
- FAKE_CODEX_SIGNED_OUT=1: the TUI starts behind a login screen (no OSC 7501) until a line
  `login` is typed.
- Then the composer: bracketed paste on, OSC 7501 `state=idle:app=codex`.
- Lazy session: SessionStart runs with the FIRST prompt (source "startup", or "resume" with
  `resume ID`; the session id FAKE_CODEX_SESSION, else a new uuid), then UserPromptSubmit.
- Each submitted message (a line, or one whole bracketed paste): prints `PROMPT: <text>`, OSC working,
  FAKE_CODEX_TURN_MS (default 300), then Stop (last_assistant_message "Done.") and OSC done.
  A message starting with / prints `SLASH COMMAND RAN: …`, with ! `SHELL MODE: …`, with $ `SKILL: …`,
  and one containing an @word `MENTION POPUP: …` (Deckhand must never send those).
- `!mcp`: starts Deckhand's MCP server as Codex does (mcp_servers.deckhand: its command and args,
  an environment of PATH and HOME plus only the variables env_vars names), runs initialize,
  tools/list and tools/call `state`, then the same call from a server given a wrong token; prints
  `FAKE MCP OK …` or `FAKE MCP BAD: <why>`.
- `!perm`: OSC blocked kind=permission, PermissionRequest hooks, then waits for a line (y) before
  the turn goes on. `!ask`: the Stop's last message ends with a question. `!exit N`: exits N.
  `!quit`: exits 0.
- FAKE_CODEX_NO_HOOKS=1: no hook ever runs (the review dialog left open, a newer Codex).
- FAKE_CODEX_LOG: JSON lines: {"argv"}, {"hook", "exit", "out", "err"} (out must stay empty),
  {"prompt"}.
- FAKE_CODEX_TOKEN_FILE: the tab's token is appended to it (the scene checks no log holds it).
"""

import hashlib
import json
import os
import subprocess
import sys
import time
import tomllib
import uuid

ESC = chr(27)
PASTE_START = ESC + "[200~"
PASTE_END = ESC + "[201~"
HOOK_KEYS = {"SessionStart": "session_start", "UserPromptSubmit": "user_prompt_submit", "PermissionRequest": "permission_request", "Stop": "stop", "SessionEnd": "session_end"}
LOG = os.environ.get("FAKE_CODEX_LOG", "")
MCP = None


def log(obj):
    if LOG:
        with open(LOG, "a") as f:
            f.write(json.dumps(obj) + "\n")


def out(*lines):
    for line in lines:
        sys.stdout.write(line + "\n")
    sys.stdout.flush()


def osc(state):
    sys.stdout.write(ESC + "]7501;state=" + state + chr(7))
    sys.stdout.flush()


def hook_hash(key, handler):
    """Codex 0.167.2: sha256 over compact, key-sorted JSON of {event_name, hooks:[handler]}."""
    h = {"type": "command", "command": handler["command"], "async": bool(handler.get("async", False)), "timeout": handler.get("timeout", 1 if key == "session_end" else 600)}
    s = json.dumps({"event_name": key, "hooks": [h]}, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "sha256:" + hashlib.sha256(s.encode()).hexdigest()


def check_args(argv):
    """(resume id or None, cwd, {event: [command]} of trusted hooks, why-bad or ""); MCP is set to
    Deckhand's MCP server's table."""
    global MCP
    a = list(argv)
    resume = None
    if a[:1] == ["resume"]:
        if len(a) < 2:
            return None, "", {}, "resume without an id"
        resume = a[1]
        a = a[2:]
    if "--no-daemon" not in a:
        return None, "", {}, "no --no-daemon"
    cwd, overrides = "", []
    i = 0
    while i < len(a):
        x = a[i]
        if x in ("-s", "-a", "-m", "-p", "--sandbox", "--ask-for-approval", "--model", "--profile", "--dangerously-bypass-hook-trust", "--dangerously-bypass-approvals-and-sandbox", "--full-auto"):
            return None, "", {}, "a flag that overrides the user's settings: " + x
        if x == "--no-daemon":
            i += 1
            continue
        if x == "-C" and i + 1 < len(a):
            cwd = a[i + 1]
            i += 2
            continue
        if x == "-c" and i + 1 < len(a):
            overrides.append(a[i + 1])
            i += 2
            continue
        return None, "", {}, "unexpected argument " + x
    if not cwd.startswith("/") or not os.path.isdir(cwd):
        return None, "", {}, "-C is not an absolute folder"
    cfg = {}
    for o in overrides:
        key, eq, value = o.partition("=")
        if not eq:
            return None, "", {}, "-c without ="
        if key == "mcp_servers.deckhand":
            try:
                MCP = tomllib.loads("v = " + value)["v"]
            except tomllib.TOMLDecodeError as e:
                return None, "", {}, f"-c {key}: not TOML ({e})"
            if not (isinstance(MCP, dict) and set(MCP) == {"command", "args", "env_vars", "tool_timeout_sec"} and MCP["command"].startswith("/") and MCP["args"] == ["mcp"] and "DECKHAND_CLAUDE_TOKEN" in MCP["env_vars"]):
                return None, "", {}, "mcp_servers.deckhand is not Deckhand's server: " + value
            continue
        if key.split(".")[0] in ("projects", "notify", "mcp_servers", "sandbox_mode", "approval_policy", "model", "profile"):
            return None, "", {}, "-c sets the user's own setting " + key
        try:
            doc = tomllib.loads("v = " + value)  # Codex: the value is TOML, else a literal string
        except tomllib.TOMLDecodeError as e:
            return None, "", {}, f"-c {key}: not TOML ({e})"
        node = cfg
        parts = key.split(".")
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        node[parts[-1]] = doc["v"]
    hooks = cfg.get("hooks", {})
    state = hooks.get("state", {})
    trusted, bad = {}, []
    for event, groups in hooks.items():
        if event == "state":
            continue
        k = HOOK_KEYS.get(event)
        if not k:
            return None, "", {}, "unknown hook event " + event
        for gi, g in enumerate(groups):
            for hi, h in enumerate(g.get("hooks", [])):
                want = state.get(f"/<session-flags>/config.toml:{k}:{gi}:{hi}", {}).get("trusted_hash")
                if want == hook_hash(k, h):
                    trusted.setdefault(event, []).append(h["command"])
                else:
                    bad.append(event)
    return resume, cwd, trusted, ",".join(bad) and ("MODIFIED " + ",".join(bad))


def mcp_session(env, calls):
    """Runs Deckhand's MCP server with env and sends initialize, then each (method, params): the
    replies' results (or errors), in order."""
    p = subprocess.Popen([MCP["command"]] + MCP["args"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)
    msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fake-codex", "version": "0"}}}, {"jsonrpc": "2.0", "method": "notifications/initialized"}]
    msgs += [{"jsonrpc": "2.0", "id": i + 1, "method": m, "params": pr} for i, (m, pr) in enumerate(calls)]
    replies = []
    for m in msgs:
        p.stdin.write(json.dumps(m) + "\n")
        p.stdin.flush()
        if "id" in m:
            r = json.loads(p.stdout.readline())
            if r.get("id") != m["id"]:
                raise ValueError(f"reply id {r.get('id')} for {m['id']}")
            replies.append(r.get("result", r.get("error")))
    p.stdin.close()
    p.wait(timeout=10)
    return replies


def mcp_check():
    if MCP is None:
        return "no mcp_servers.deckhand"
    env = {k: os.environ[k] for k in ("PATH", "HOME") if k in os.environ}  # Codex's base, not the tab's
    env.update({k: os.environ[k] for k in MCP["env_vars"] if k in os.environ})
    init, tools, state = mcp_session(env, [("tools/list", {}), ("tools/call", {"name": "state", "arguments": {}})])
    if "Deckhand" not in init.get("instructions", ""):
        return "no instructions"
    ro = {t["name"]: t["annotations"]["readOnlyHint"] for t in tools["tools"]}
    if not ro.get("state") or ro.get("show_file") or ro.get("browser_click") is not False:
        return f"readOnlyHint wrong: {ro}"
    out = json.loads(state["content"][0]["text"])
    if state["isError"] or not out.get("ok"):
        return "state failed: " + state["content"][0]["text"][:200]
    env["DECKHAND_CLAUDE_TOKEN"] = "0" * 64
    _, wrong = mcp_session(env, [("tools/call", {"name": "browser_tabs", "arguments": {}})])
    if not wrong["isError"] or "refused" not in wrong["content"][0]["text"]:
        return "a wrong token was not refused: " + wrong["content"][0]["text"][:200]
    return ""


def read_message():
    line = sys.stdin.readline()
    if not line:
        return None
    if PASTE_START in line and PASTE_END not in line:
        parts = [line]
        while True:
            more = sys.stdin.readline()
            if not more:
                break
            parts.append(more)
            if PASTE_END in more:
                break
        line = "".join(parts)
    return line.replace(PASTE_START, "").replace(PASTE_END, "").rstrip("\r\n")


class Fake:
    def __init__(self, cwd, hooks, resume):
        self.cwd = cwd
        self.hooks = {} if os.environ.get("FAKE_CODEX_NO_HOOKS") == "1" else hooks
        self.resume = resume
        self.session = None
        self.turn_id = 0

    def run_hooks(self, event, extra):
        data = {"session_id": self.session or "", "transcript_path": f"/fake-home/.codex/sessions/2026/11/12/rollout-x-{self.session}.jsonl", "cwd": self.cwd, "hook_event_name": event, "model": "gpt-5.5"}
        data.update(extra)
        for cmd in self.hooks.get(event, []):
            try:
                p = subprocess.run(["/bin/sh", "-c", cmd], input=json.dumps(data), capture_output=True, text=True, timeout=10)
                log({"hook": event, "exit": p.returncode, "out": p.stdout, "err": p.stderr[-300:]})
            except subprocess.TimeoutExpired:
                log({"hook": event, "timeout": True})

    def turn(self, text):
        log({"prompt": text})
        lead = text.lstrip(" \t\n")
        if lead[:1] == "/":
            out("SLASH COMMAND RAN: " + lead)
        elif lead[:1] == "!" and not lead.startswith(("!perm", "!ask", "!exit", "!quit", "!mcp")):
            out("SHELL MODE: " + lead)
        elif lead[:1] == "$":
            out("SKILL: " + lead)
        for w in text.split():
            if w.startswith("@") and len(w) > 1:
                out("MENTION POPUP: " + w)
        if self.session is None:  # Codex starts its session lazily, with the first prompt
            self.session = self.resume or os.environ.get("FAKE_CODEX_SESSION") or str(uuid.uuid4())
            out(f"session {self.session}")
            self.run_hooks("SessionStart", {"source": "resume" if self.resume else "startup"})
        self.turn_id += 1
        self.run_hooks("UserPromptSubmit", {"turn_id": str(self.turn_id), "prompt": text})
        out("PROMPT: " + text.replace("\n", " | "))
        osc("working:app=codex")
        if text == "!mcp":
            try:
                why = mcp_check()
            except Exception as e:  # noqa: BLE001 (the scene reads the line)
                why = f"{type(e).__name__}: {e}"
            out(("FAKE MCP BAD: " + why) if why else "FAKE MCP OK state, wrong token refused")
        if text.startswith("!exit"):
            parts = text.split()
            sys.exit(int(parts[1]) if len(parts) > 1 else 1)
        if text == "!perm":
            osc("blocked:app=codex:kind=permission")
            self.run_hooks("PermissionRequest", {"turn_id": str(self.turn_id), "tool_name": "exec", "tool_input": {"command": "touch x"}})
            out("PERMISSION? (y/n)")
            sys.stdin.readline()
            osc("working:app=codex")
        time.sleep(int(os.environ.get("FAKE_CODEX_TURN_MS", "300")) / 1000)
        last = "Which one do you want?" if text == "!ask" else "Done."
        self.run_hooks("Stop", {"turn_id": str(self.turn_id), "last_assistant_message": last})
        osc("done:app=codex")
        out("done")


def main():
    argv = sys.argv[1:]
    if argv[:2] == ["login", "status"]:
        sys.exit(1 if os.environ.get("FAKE_CODEX_SIGNED_OUT") == "1" else 0)
    log({"argv": argv})
    tok_file = os.environ.get("FAKE_CODEX_TOKEN_FILE", "")
    if tok_file:
        with open(tok_file, "a") as f:
            f.write(os.environ.get("DECKHAND_CLAUDE_TOKEN", "") + "\n")
    resume, cwd, hooks, why = check_args(argv)
    if why and not why.startswith("MODIFIED"):
        out("FAKE CODEX ARGS BAD: " + why)
        sys.exit(3)
    out("FAKE CODEX ARGS OK")
    if resume:
        out(f"resume {resume}")
    if why:
        out("HOOKS NEED REVIEW: " + why)
    else:
        out(f"FAKE CODEX TRUST OK {sum(len(v) for v in hooks.values())}")
    if os.environ.get("FAKE_CODEX_SIGNED_OUT") == "1":
        out("Sign in with ChatGPT (type login)")
        while True:
            line = sys.stdin.readline()
            if not line:
                return
            if line.strip() == "login":
                break
    fake = Fake(cwd, hooks, resume)
    sys.stdout.write(ESC + "[?2004h")  # bracketed paste, as Codex's composer turns on
    osc("idle:app=codex")
    while True:
        sys.stdout.write("› ")
        sys.stdout.flush()
        line = read_message()
        if line is None:
            break
        if not line:
            continue
        if line == "!quit":
            break
        fake.turn(line)
    osc("clear")
    sys.stdout.write(ESC + "[?2004l")
    out("bye")


if __name__ == "__main__":
    main()
