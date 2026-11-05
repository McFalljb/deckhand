#!/usr/bin/env python3
"""A fake `claude` for pi-desk's Claude-tab scenes (never the real one; no network, no ~/.claude).

pi-desk starts it in a Claude tab's PTY as `fake-claude.py --plugin-dir DIR [--resume ID] [args…]`.
It behaves like Claude Code where pi-desk can see it: it runs the plugin's hooks (DIR/hooks/
hooks.json) with realistic JSON on stdin, and the plugin's `pi-desk` command, and shows a prompt.

- Prints `FAKE CLAUDE ARGS: …` and `session <id>` (the --resume id, else a new uuid4); exits 3
  without --plugin-dir.
- SessionStart hooks (source "resume" with --resume, else "startup").
- FAKE_CLAUDE_SCRIPT: a file of CLI calls, one per line (shell words), run as DIR/bin/deckhand
  before the prompt; each logged to FAKE_CLAUDE_LOG as {"cli": args, "exit": n, "out": stdout}.
- The prompt loop (line mode; bracketed paste markers are stripped): each submitted line runs the
  UserPromptSubmit hooks (prompt = the line), prints `PROMPT: <line>` and `CONTEXT: <n> chars`
  (and its first line), logs {"prompt", "context"}, prints "working…", sleeps FAKE_CLAUDE_TURN_MS
  (default 300), runs the Stop hooks and prints "done". `!cli ARGS` also runs the CLI; `!perm`
  runs Notification hooks (permission_prompt) and waits for one line before Stop; `!quit` exits.
- In `!cli` arguments `{browser}` and `{app}` become the first browser and app tab of the session
  (`{lastapp}`: the last app tab)
  (from `pi-desk tabs` and `pi-desk state`).
- Hook groups with a "matcher" (PreToolUse, PostToolUse) run only for a tool name it lists
  (`A|B`, exact names, as Claude Code reads a plain matcher). Hooks marked "async" run in order,
  like the rest (the fake waits for them), and their stdout is logged (it must stay empty).
- A bracketed paste is one message, whatever its lines (as Claude Code's prompt takes it).
- `!todo`: PostToolUse on TodoWrite with a list of three (done, in progress, pending).
  `!tasks`: TaskCreated (two), PostToolUse on TaskUpdate (in progress), TaskCompleted.
  `!agent`: PreToolUse on the Agent tool (Explore, its description) and SubagentStart (agent-1).
  `!agent-done`: SubagentStop for agent-1 (with a last message that must never reach pi-desk).
  `!exit N`: claude exits with code N (pi-desk's dead tab bar).
  `!model NAME`: PostModelSwitch to NAME. `!ask`: the turn's Stop has a last message ending
  with a question. `!fail`: the turn ends with StopFailure (rate_limit) instead of Stop.
  `!ask-wake` / `!fail-wake`: as `!ask` / `!fail`, then FAKE_CLAUDE_WAKE_MS (default 1500) later a
  turn with no UserPromptSubmit (a background wake, /loop) whose Stop ends with a statement.
  `!idle-prompt`: after the turn, Notification idle_prompt (as Claude Code sends a while later).
- SessionStart has `model` (FAKE_CLAUDE_MODEL, default claude-opus-5; "-" = none). Its hooks'
  stdout is logged as {"session_start_out": …} (pi-desk's sessionTitle).
- FAKE_CLAUDE_PROJECTS: a FAKE Claude config dir's projects/ folder (never the real one): the
  transcript path is <it>/-fake/<session>.jsonl and the file is created there (empty).
- `--settings JSON` (pi-desk's read-only profile): its hooks run too, after the plugin's (matcher
  "*" = every tool; SessionStart: the read-only ack). FAKE_CLAUDE_IGNORE_SETTINGS=1: they do not
  (an older Claude Code that ignores them). `!bash CMD`: PreToolUse for the Bash tool with that command; `!tool NAME`:
  PreToolUse for that tool; each hook's exit and stdout are logged with the tool's input
  ({"hook", "tool", "input", "exit", "out", "err"}) and printed as `TOOL <name> -> exit N`.
- `!bg`: PostToolUse on a background Bash (`npm run dev`, its backgroundTaskId); from then on every
  Stop carries `background_tasks` (that shell and a monitor) and `session_crons` (a recurring
  check), as Claude Code's Stop does. `!bg-done`: nothing runs any more (the next Stops carry
  empty arrays). `!sub-work`: a subagent (Plan, agent-2) starts, calls tools (PreToolUse with its
  agent_id) and writes its own todos (TodoWrite with its agent_id); it stays running.
- FAKE_CLAUDE_NO_HOOKS=1, or the argument `--fake-no-hooks`: no hook ever runs (`disableAllHooks`,
  a managed hooks policy).
- `!orphan ARGS`: the CLI from a process that is NOT below the tab's (double fork: re-parented to
  launchd) with the same environment and token; logged as {"orphan": args, "exit", "out"}.
- FAKE_CLAUDE_OSC_LAG_MS: also report OSC 7501 working at a turn's start, and idle this long
  after its Stop hook (then print `OSC IDLE`): the two signals disagree for a while.
- FAKE_CLAUDE_SESSION: the session id of a new conversation (else a new uuid4).
- FAKE_CLAUDE_TOKEN_FILE: the tab's token is appended to it (the scene checks no log holds it).
"""

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import uuid

ESC = chr(27)
PASTE_START = ESC + "[200~"
PASTE_END = ESC + "[201~"


def osc7501(state):
    """Claude's own program status (OSC 7501), as Claude Code reports it."""
    sys.stdout.write(ESC + "]7501;state=" + state + ":app=claude-code" + chr(7))
    sys.stdout.flush()


def out(*lines):
    for line in lines:
        sys.stdout.write(line + "\n")
    sys.stdout.flush()


def parse_args(argv):
    plugin_dir, resume, rest = None, None, []
    global SETTINGS, NO_HOOKS
    SETTINGS = None
    NO_HOOKS = "--fake-no-hooks" in argv
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--plugin-dir" and i + 1 < len(argv):
            plugin_dir = argv[i + 1]
            i += 2
            continue
        if a == "--settings" and i + 1 < len(argv):
            SETTINGS = json.loads(argv[i + 1])
            rest.append(a)
            i += 1
            continue
        if a in ("--resume", "-r") and i + 1 < len(argv):
            resume = argv[i + 1]
            i += 2
            continue
        rest.append(a)
        i += 1
    return plugin_dir, resume, rest


class Fake:
    def __init__(self, plugin_dir, session_id, source):
        self.dir = os.path.abspath(plugin_dir)
        self.session_id = session_id
        self.source = source
        self.codes = []  # the last PreToolUse hooks' exit codes
        self.cwd = os.getcwd()
        # a transcript path as Claude Code would give it: never read; created only in a fake
        # config dir the scene names (FAKE_CLAUDE_PROJECTS)
        self.transcript = os.path.join(tempfile.gettempdir(), "fake-claude-none", session_id + ".jsonl")
        projects = os.environ.get("FAKE_CLAUDE_PROJECTS", "")
        if projects:
            os.makedirs(os.path.join(projects, "-fake"), exist_ok=True)
            self.transcript = os.path.join(projects, "-fake", session_id + ".jsonl")
            open(self.transcript, "a").close()
        self.log_path = os.environ.get("FAKE_CLAUDE_LOG", "")
        with open(os.path.join(self.dir, "hooks", "hooks.json")) as f:
            self.hooks = json.load(f).get("hooks", {})
        # the --settings hooks join the plugin's (Claude Code merges hooks from every source)
        # FAKE_CLAUDE_IGNORE_SETTINGS=1: a Claude Code that ignores them (pi-desk must notice: no ack)
        settings = {} if os.environ.get("FAKE_CLAUDE_IGNORE_SETTINGS") == "1" else (SETTINGS or {})
        for event, groups in (settings.get("hooks") or {}).items():
            self.hooks.setdefault(event, []).extend(groups)
        if os.environ.get("FAKE_CLAUDE_NO_HOOKS") == "1" or NO_HOOKS:  # disableAllHooks: nothing runs
            self.hooks = {}
        self.bg = None  # background work Stop reports (None: a Claude Code without the arrays)

    def log(self, obj):
        if not self.log_path:
            return
        with open(self.log_path, "a") as f:
            f.write(json.dumps(obj) + "\n")

    def env(self):
        e = dict(os.environ)
        e["CLAUDE_PLUGIN_ROOT"] = self.dir
        e["CLAUDE_PROJECT_DIR"] = self.cwd
        return e

    def run_hooks(self, event, extra, tool=None):
        """Runs the event's hook commands (those whose matcher lists `tool`); returns their stdout, joined."""
        data = {
            "session_id": self.session_id,
            "transcript_path": self.transcript,
            "cwd": self.cwd,
            "permission_mode": "default",
            "hook_event_name": event,
        }
        data.update(extra)
        outs = []
        for group in self.hooks.get(event, []):
            matcher = group.get("matcher", "")
            if matcher and matcher != "*" and (tool is None or tool not in matcher.split("|")):
                continue
            for h in group.get("hooks", []):
                if h.get("type") != "command":
                    continue
                cmd = h["command"].replace("${CLAUDE_PLUGIN_ROOT}", self.dir)
                try:
                    p = subprocess.run(["/bin/sh", "-c", cmd], input=json.dumps(data), capture_output=True, text=True, env=self.env(), timeout=h.get("timeout", 60))
                except subprocess.TimeoutExpired:
                    out(f"[hook {event} timed out]")
                    continue
                entry = {"hook": event, "tool": tool, "async": bool(h.get("async")), "exit": p.returncode, "out": p.stdout, "err": p.stderr}
                if event == "PreToolUse":
                    entry["input"] = extra.get("tool_input")
                    self.codes.append(p.returncode)
                self.log(entry)
                outs.append(p.stdout)
        return "".join(outs)

    def run_cli(self, args):
        e = self.env()
        e["PATH"] = os.path.join(self.dir, "bin") + os.pathsep + e.get("PATH", "")
        p = subprocess.run([os.path.join(self.dir, "bin", "deckhand")] + args, capture_output=True, text=True, env=e, timeout=180)
        self.log({"cli": args, "exit": p.returncode, "out": p.stdout})
        first = p.stdout.strip().splitlines()[0] if p.stdout.strip() else ""
        out(f"CLI {' '.join(args)} -> exit {p.returncode}: {first[:160]}")
        return p

    def resolve(self, args):
        """{browser} and {app}: the session's first browser and app tab ids; {lastapp}: its last app tab."""
        if not any("{browser}" in a or "{app}" in a or "{lastapp}" in a for a in args):
            return args
        e = self.env()
        def cli(words):
            # bin/pi-desk: the old name, an alias of bin/deckhand (pi-kit and older sessions use it)
            p = subprocess.run([os.path.join(self.dir, "bin", "pi-desk")] + words, capture_output=True, text=True, env=e, timeout=60)
            try:
                return json.loads(p.stdout)
            except ValueError:
                return {}
        browser, app, last = "0", "0", "0"
        tabs = cli(["tabs"]).get("tabs") or []
        if tabs:
            browser = str(tabs[0].get("tab", 0))
        content = cli(["state"]).get("content", "")
        m = re.search(r"```+deckhand state\n(.*)\n```", content, re.S)
        try:
            snap = json.loads(m.group(1)) if m else {}
        except ValueError:
            snap = {}
        for sess in snap.get("open_sessions", []):
            for tab in sess.get("tabs", []):
                if tab.get("kind") == "app":
                    if app == "0":
                        app = str(tab.get("id", 0))
                    last = str(tab.get("id", 0))
        return [a.replace("{browser}", browser).replace("{app}", app).replace("{lastapp}", last) for a in args]

    def orphan(self, args):
        """The CLI from a process outside the tab's tree: same env, same token."""
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            if os.fork() != 0:
                os._exit(0)
            # the grandchild: its parent exits, it is re-parented (launchd)
            for _ in range(100):
                if os.getppid() == 1:
                    break
                time.sleep(0.02)
            p = subprocess.run([os.path.join(self.dir, "bin", "pi-desk")] + args, capture_output=True, text=True, env=self.env(), timeout=60)
            os.write(w, json.dumps({"orphan": args, "ppid": os.getppid(), "exit": p.returncode, "out": p.stdout}).encode())
            os._exit(0)
        os.close(w)
        os.waitpid(pid, 0)
        data = b""
        while True:
            chunk = os.read(r, 65536)
            if not chunk:
                break
            data += chunk
        os.close(r)
        try:
            obj = json.loads(data)
        except ValueError:
            obj = {"orphan": args, "exit": -1, "out": data.decode(errors="replace")}
        self.log(obj)
        out(f"ORPHAN {' '.join(args)} -> exit {obj.get('exit')}: {obj.get('out', '').strip()[:160]}")

    def stop_extra(self):
        """Stop's background_tasks and session_crons, once `!bg` ran."""
        if self.bg is None:
            return {}
        return {"background_tasks": list(self.bg["tasks"]), "session_crons": list(self.bg["crons"])}

    def tool(self, name, tool_input, response, agent=None):
        """A tool call as Claude Code hooks it: PreToolUse, then PostToolUse with its response."""
        base = {"tool_name": name, "tool_input": tool_input, "tool_use_id": "toolu_fake_" + name}
        if agent:  # inside a subagent: its id and type
            base.update(agent)
        self.run_hooks("PreToolUse", base, tool=name)
        self.run_hooks("PostToolUse", dict(base, tool_response=response, duration_ms=3), tool=name)

    def turn(self, line):
        ctx = ""
        raw = self.run_hooks("UserPromptSubmit", {"prompt": line}).strip()
        if raw:
            try:
                ctx = json.loads(raw).get("hookSpecificOutput", {}).get("additionalContext", "")
            except ValueError:
                ctx = raw  # plain stdout is context too
        out(f"PROMPT: {line}", f"CONTEXT: {len(ctx)} chars")
        if ctx:
            out("CONTEXT> " + ctx.splitlines()[0][:160])
        self.log({"prompt": line, "context": ctx})
        if line.startswith("!cli "):
            self.run_cli(self.resolve(shlex.split(line[5:])))
        if line.startswith("!orphan "):
            self.orphan(shlex.split(line[8:]))
        if line == "!todo":
            todos = [
                {"content": "Read the config", "status": "completed", "activeForm": "Reading the config"},
                {"content": "Fix the header", "status": "in_progress", "activeForm": "Fixing the header"},
                {"content": "Run the tests", "status": "pending", "activeForm": "Running the tests"},
            ]
            self.tool("TodoWrite", {"todos": todos}, {"oldTodos": [], "newTodos": todos})
        if line == "!tasks":
            self.run_hooks("TaskCreated", {"task_id": "1", "task_subject": "Draft the plan", "task_description": "the details"})
            self.run_hooks("TaskCreated", {"task_id": "2", "task_subject": "Review the plan"})
            self.tool("TaskUpdate", {"taskId": "1", "status": "in_progress", "activeForm": "Drafting the plan"}, {"success": True})
            self.run_hooks("TaskCompleted", {"task_id": "1", "task_subject": "Draft the plan"})
        if line == "!agent":
            self.run_hooks("PreToolUse", {"tool_name": "Agent", "tool_input": {"subagent_type": "Explore", "description": "Find the config files", "prompt": "FAKE SECRET PROMPT"}, "tool_use_id": "toolu_fake_agent"}, tool="Agent")
            self.run_hooks("SubagentStart", {"agent_id": "agent-1", "agent_type": "Explore"})
        if line == "!bg":
            self.tool("Bash", {"command": "npm run dev", "description": "Start the dev server", "run_in_background": True}, {"stdout": "", "stderr": "", "interrupted": False, "backgroundTaskId": "bash_1"})
            self.bg = {
                "tasks": [
                    {"id": "bash_1", "type": "shell", "status": "running", "description": "Start the dev server", "command": "npm run dev"},
                    {"id": "mon_1", "type": "monitor", "status": "running", "description": "watch CI", "server": "ci", "tool": "watch"},
                ],
                "crons": [{"id": "cron_1", "schedule": "*/5 * * * *", "recurring": True, "prompt": "check the build"}],
            }
        if line == "!bg-done":
            self.bg = {"tasks": [], "crons": []}
        if line == "!sub-work":
            agent = {"agent_id": "agent-2", "agent_type": "Plan"}
            self.run_hooks("PreToolUse", {"tool_name": "Agent", "tool_input": {"subagent_type": "Plan", "description": "Plan the migration", "prompt": "FAKE SECRET PROMPT"}, "tool_use_id": "toolu_fake_agent2"}, tool="Agent")
            self.run_hooks("SubagentStart", agent)
            self.tool("Grep", {"pattern": "FAKE SECRET"}, {"numFiles": 2}, agent=agent)
            todos = [
                {"content": "Read the schema", "status": "completed", "activeForm": "Reading the schema"},
                {"content": "Draft the steps", "status": "in_progress", "activeForm": "Drafting the steps"},
                {"content": "List the risks", "status": "pending", "activeForm": "Listing the risks"},
            ]
            self.tool("TodoWrite", {"todos": todos}, {"oldTodos": [], "newTodos": todos}, agent=agent)
            self.tool("Read", {"file_path": "/x/schema.sql"}, {"type": "text"}, agent=agent)
        if line == "!agent-done":
            self.run_hooks("SubagentStop", dict({"agent_id": "agent-1", "agent_type": "Explore", "agent_transcript_path": self.transcript, "last_assistant_message": "FAKE SECRET RESULT", "stop_hook_active": False}, **self.stop_extra()))
        if line.startswith("!model "):
            self.run_hooks("PostModelSwitch", {"from_model": "claude-opus-5", "to_model": line.split()[1]})
        if line.startswith("!bash ") or line.startswith("!tool "):
            name, ti = ("Bash", {"command": line[6:], "description": "fake"}) if line.startswith("!bash ") else (line[6:].strip(), {})
            self.codes = []
            self.run_hooks("PreToolUse", {"tool_name": name, "tool_input": ti, "tool_use_id": "toolu_fake_pre"}, tool=name)
            blocked = any(c == 2 for c in self.codes)
            out(f"TOOL {name} -> {'blocked' if blocked else 'runs'} (exits {self.codes})")
        if line.startswith("!exit "):
            out("bye")
            sys.stdout.flush()
            os._exit(int(line.split()[1]))
        if line == "!perm":
            self.run_hooks("Notification", {"message": "Claude needs your permission to use Bash", "title": "Permission needed", "notification_type": "permission_prompt"})
            out("PERMISSION? (y/n)")
            answer = sys.stdin.readline()
            out(f"ANSWER: {clean(answer)}")
        lag = int(os.environ.get("FAKE_CLAUDE_OSC_LAG_MS", "0"))
        if lag:
            osc7501("working")
        out("working…")
        time.sleep(int(os.environ.get("FAKE_CLAUDE_TURN_MS", "300")) / 1000)
        if line in ("!fail", "!fail-wake"):
            self.run_hooks("StopFailure", {"error": "rate_limit", "error_details": "429 Too Many Requests", "last_assistant_message": "API Error: Rate limit reached"})
            out("API Error: Rate limit reached")
        else:
            last = "Which file should I change?" if line in ("!ask", "!ask-wake", "!idle-prompt") else "done"
            self.run_hooks("Stop", dict({"stop_hook_active": False, "last_assistant_message": last}, **self.stop_extra()))
            out("done")
        if lag:  # Claude's own status says idle a while after its Stop hook
            time.sleep(lag / 1000)
            osc7501("idle")
            out("OSC IDLE")
        if line == "!idle-prompt":
            time.sleep(int(os.environ.get("FAKE_CLAUDE_WAKE_MS", "1500")) / 1000)
            self.run_hooks("Notification", {"message": "Claude is waiting for your input", "notification_type": "idle_prompt"})
            out("idle prompt")
        if line in ("!ask-wake", "!fail-wake"):
            # a background wake: Claude works again with no UserPromptSubmit, then stops
            time.sleep(int(os.environ.get("FAKE_CLAUDE_WAKE_MS", "1500")) / 1000)
            out("woke: working…")
            self.run_hooks("Stop", {"stop_hook_active": False, "last_assistant_message": "All done, the tests pass."})
            out("done")


def read_message():
    """One message from the prompt: a line, or a whole bracketed paste (its lines kept)."""
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
    return clean(line)


def clean(line):
    return line.replace(PASTE_START, "").replace(PASTE_END, "").rstrip("\r\n")


def main():
    plugin_dir, resume, rest = parse_args(sys.argv[1:])
    out("FAKE CLAUDE ARGS: " + " ".join(sys.argv[1:]))
    if not plugin_dir or not os.path.isfile(os.path.join(plugin_dir, "hooks", "hooks.json")):
        out("fake claude: --plugin-dir DIR (with hooks/hooks.json) is required")
        sys.exit(3)
    session_id = resume or os.environ.get("FAKE_CLAUDE_SESSION") or str(uuid.uuid4())
    out(f"session {session_id}")
    fake = Fake(plugin_dir, session_id, "resume" if resume else "startup")
    fake.log({"start": sys.argv[1:], "session": session_id})
    tok_file = os.environ.get("FAKE_CLAUDE_TOKEN_FILE", "")
    if tok_file:  # the scene checks pi-desk's own logs never hold it
        with open(tok_file, "a") as f:
            f.write(os.environ.get("PI_DESK_CLAUDE_TOKEN", "") + "\n")
    start = {"source": fake.source}
    model = os.environ.get("FAKE_CLAUDE_MODEL", "claude-opus-5")
    if model != "-":
        start["model"] = model
    fake.log({"session_start_out": fake.run_hooks("SessionStart", start)})
    script = os.environ.get("FAKE_CLAUDE_SCRIPT", "")
    if script:
        with open(script) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    fake.run_cli(shlex.split(line))
    sys.stdout.write(ESC + "[?2004h")  # bracketed paste, as Claude Code turns on
    while True:
        sys.stdout.write("> ")
        sys.stdout.flush()
        line = read_message()
        if line is None:
            break
        if not line:
            continue
        if line == "!quit":
            break
        fake.turn(line)
    sys.stdout.write(ESC + "[?2004l")
    out("bye")


if __name__ == "__main__":
    main()
