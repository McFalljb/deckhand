#!/usr/bin/env python3
"""A demo pi for the README screenshot and clip (tests/scripts/readme-shot.sh). Never a real pi.

It draws a static, pi-like conversation about the fake recipe-box project, then
plays the pi integration's bridge over Deckhand's socket (deckhand --ctl with the tab's
single-use DECKHAND_TOKEN): pi.session, a pi.status per session (g1 working, n1
waiting, the rest idle), and a todos panel. With DEMO_LIVE=1 the r1 session is
played live instead (live() below): the prompt is typed into it, then the turn runs
step by step. Every word on screen is made up for the picture.
"""
import json, os, re, shutil, sys

args = sys.argv[1:]
sid = "demo"
for i, a in enumerate(args):
    if a in ("--session", "--session-id") and i + 1 < len(args):
        sid = os.path.basename(args[i + 1]).split("_")[-1].replace(".jsonl", "")

cols, rows = shutil.get_terminal_size((100, 40))
W = max(40, cols)
E = "\x1b["
RST, BOLD, DIM = E + "0m", E + "1m", E + "2m"
FG = lambda r, g, b: E + "38;2;%d;%d;%dm" % (r, g, b)
BG = lambda r, g, b: E + "48;2;%d;%d;%dm" % (r, g, b)
ACC, MUT, OK, ADD, DEL = FG(138, 190, 255), FG(128, 134, 148), FG(140, 200, 120), FG(140, 200, 120), FG(230, 120, 120)
USER_BG, TOOL_BG = BG(52, 56, 66), BG(30, 46, 36)


def out(s):
    sys.stdout.write(s.replace("\n", "\r\n"))


def block(bg, lines):
    """Lines on a full-width background, one column of padding."""
    out(bg + " " * W + RST + "\n")
    for ln in lines:
        vis = len(re.sub(r"\x1b\[[0-9;]*m", "", ln))
        out(bg + " " + ln + bg + " " * max(0, W - 1 - vis) + RST + "\n")
    out(bg + " " * W + RST + "\n")


def live():
    """r1 played live: an empty pi; typed keys go to its editor; Enter runs the turn,
    one step a second, with pi.status and the todos panel following it."""
    import select, signal, socket, time, tty
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(os.environ["DECKHAND_SOCKET"])

    def send(m):
        m.setdefault("v", 1)
        sock.sendall((json.dumps(m) + "\n").encode())

    def todos(done):
        names = ["Read the importer", "parseCsv with a header row", "Tests for quoted fields",
                 "Wire it to the Import button"]
        rows = [{"text": "Todos %d/4" % done, "head": True}]
        rows += [{"text": "✓ " + n, "tone": "dim"} if i < done else {"text": "○ " + n} for i, n in enumerate(names)]
        send({"id": "p%d" % done, "type": "panel.set", "panel": "todos", "title": "Todos", "rows": rows})

    def status(agent):
        send({"id": "s" + agent, "type": "pi.status", "agent": agent, "waiting": False, "blockers": []})

    send({"id": "h", "type": "hello", "token": os.environ.get("DECKHAND_TOKEN", "")})
    send({"id": "s", "type": "pi.session", "pi_session_id": sid, "session_file": "", "cwd": os.getcwd()})
    status("idle")
    sock.setblocking(False)
    tty.setraw(0)
    resized = [False]
    signal.signal(signal.SIGWINCH, lambda *_: resized.__setitem__(0, True))
    # what is on screen: ("text", line) or ("block", bg, lines)
    items, typed, prompt = [], "", ""
    G = lambda s: ADD + s + RST + TOOL_BG
    steps = [
        lambda: (items.append(("text", " I'll look at the existing importer and the fixture first.")), todos(0)),
        lambda: (items.append(("block", TOOL_BG, [BOLD + "read" + RST + TOOL_BG + " src/import.ts",
                                                 MUT + "  48 lines" + RST + TOOL_BG])), todos(1)),
        lambda: (items.append(("block", TOOL_BG, [BOLD + "edit" + RST + TOOL_BG + " src/import.ts",
                                                 G("+ export function parseCsv(text: string): Recipe[] {"),
                                                 G("+   const [header, ...rows] = text.trim().split(/\\r?\\n/);"),
                                                 G("+   const cols = header.split(',');"),
                                                 G("+   return rows.map((row) => toRecipe(cols, splitRow(row)));"),
                                                 G("+ }")])), todos(2)),
        lambda: (items.append(("block", TOOL_BG, [BOLD + "$ npm test -- import" + RST + TOOL_BG,
                                                 OK + "  ✓ parses the header row" + RST + TOOL_BG,
                                                 OK + "  ✓ splits ingredients on semicolons" + RST + TOOL_BG,
                                                 OK + "  ✓ keeps quoted commas inside a field" + RST + TOOL_BG,
                                                 MUT + "  3 passed (212 ms)" + RST + TOOL_BG])), todos(3)),
        lambda: (items.append(("text", " Done. " + BOLD + "parseCsv" + RST + " reads the header and maps each row to a")),
                 items.append(("text", " " + BOLD + "Recipe" + RST + "; quoted fields may contain commas. The three new tests")),
                 items.append(("text", " pass. Next I can wire it to the " + ACC + "Import" + RST + " button.")),
                 status("idle")),
    ]
    step, next_at, spin = -1, 0.0, 0

    def fit(ln, w):
        """ln cut to w visible columns (escapes kept), so a narrow pane never wraps it"""
        res, vis = "", 0
        for tok in re.findall(r"\x1b\[[0-9;]*m|.", ln):
            if tok.startswith("\x1b"):
                res += tok
            elif vis < w:
                res += tok
                vis += 1
        return res, vis

    def draw():
        cols, rows = shutil.get_terminal_size((100, 40))
        w = max(30, cols)
        lines = [""]
        for it in items:
            if it[0] == "text":
                lines += [fit(it[1], w)[0], ""]
            else:
                bg = it[1]
                lines.append(bg + " " * w + RST)
                for ln in it[2]:
                    t, vis = fit(" " + ln, w)
                    lines.append(bg + t + bg + " " * max(0, w - vis) + RST)
                lines += [bg + " " * w + RST, ""]
        if 0 <= step < len(steps) - 1:
            lines.append(" " + ACC + "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"[spin % 10] + RST + MUT + " Working…" + RST)
        bottom = rows - 4
        lines = lines[-(bottom - 1):]
        buf = E + "2J" + E + "H" + "\r\n".join(lines)
        foot_l, foot_r = "~/code/recipe-box (main)", ("↑18k ↓2.4k  $0.031  9%  demo-model" if step >= 0 else "↑0 ↓0  $0.000  0%  demo-model")
        buf += E + "%d;1H" % bottom + MUT + "─" * w + RST + "\r\n " + fit(typed, w - 2)[0] + "\r\n" + MUT + "─" * w + RST + "\r\n"
        buf += MUT + foot_l + " " * max(1, w - len(foot_l) - len(foot_r)) + foot_r + RST
        buf += E + "%d;%dH" % (bottom + 1, 2 + min(len(typed), w - 3))
        sys.stdout.write(buf)
        sys.stdout.flush()

    draw()
    while True:
        r, _, _ = select.select([0, sock], [], [], 0.1)
        if sock in r:
            try:
                while sock.recv(65536):
                    pass
            except BlockingIOError:
                pass
        if 0 in r:
            for ch in os.read(0, 256).decode("utf-8", "replace"):
                if ch == "\r" and step < 0 and typed:
                    prompt, typed = typed, ""
                    words, row = prompt.split(" "), ""
                    lines = []
                    for wd in words:  # the prompt wrapped at 70 columns, as pi's own box does
                        if len(row) + len(wd) + 1 > 70:
                            lines.append(row)
                            row = ""
                        row = (row + " " + wd).strip()
                    lines.append(row)
                    items.append(("block", USER_BG, lines))
                    status("working")
                    step, next_at = 0, time.time() + 0.8
                elif ch >= " " and step < 0:
                    typed += ch
        if 0 <= step < len(steps) and time.time() >= next_at:
            steps[step]()
            step += 1
            next_at = time.time() + 1.0
        spin += 1
        resized[0] = False
        draw()


if os.environ.get("DEMO_LIVE") == "1" and sid == "r1":
    live()

out(E + "2J" + E + "H")
out("\n")
block(USER_BG, ["Import recipes from a CSV export. The file in fixtures/recipes.csv",
                "has a header row; ingredients are separated by semicolons."])
out("\n")
out(" I'll look at the existing importer and the fixture first.\n\n")
block(TOOL_BG, [BOLD + "read" + RST + TOOL_BG + " src/import.ts", MUT + "  48 lines" + RST + TOOL_BG])
out("\n")
block(TOOL_BG, [BOLD + "edit" + RST + TOOL_BG + " src/import.ts",
                ADD + "+ export function parseCsv(text: string): Recipe[] {" + RST + TOOL_BG,
                ADD + "+   const [header, ...rows] = text.trim().split(/\\r?\\n/);" + RST + TOOL_BG,
                ADD + "+   const cols = header.split(',');" + RST + TOOL_BG,
                ADD + "+   return rows.map((row) => toRecipe(cols, splitRow(row)));" + RST + TOOL_BG,
                ADD + "+ }" + RST + TOOL_BG])
out("\n")
block(TOOL_BG, [BOLD + "$ npm test -- import" + RST + TOOL_BG,
                OK + "  ✓ parses the header row" + RST + TOOL_BG,
                OK + "  ✓ splits ingredients on semicolons" + RST + TOOL_BG,
                OK + "  ✓ keeps quoted commas inside a field" + RST + TOOL_BG,
                MUT + "  3 passed (212 ms)" + RST + TOOL_BG])
out("\n")
out(" Done. " + BOLD + "parseCsv" + RST + " reads the header, maps each row to a " + BOLD + "Recipe" + RST + ",\n")
out(" and splits ingredients on semicolons. Quoted fields may contain commas.\n")
out(" The three new tests pass. Next I can wire it to the " + ACC + "Import" + RST + " button.\n")

# the editor and footer at the bottom, as pi draws them
bottom = rows - 4
out(E + "%d;1H" % bottom)
out(MUT + "─" * W + RST + "\n")
out(" \n")
out(MUT + "─" * W + RST + "\n")
foot_l = "~/" + os.path.relpath(os.getcwd(), os.path.expanduser("~")) + " (main)"
foot_r = "↑18k ↓2.4k  $0.031  9%  demo-model"
out(MUT + foot_l + " " * max(1, W - len(foot_l) - len(foot_r)) + foot_r + RST)
out(E + "%d;2H" % (bottom + 1))
sys.stdout.flush()

todos = {"id": "p1", "v": 1, "type": "panel.set", "panel": "todos", "title": "Todos", "rows": [
    {"text": "Todos 3/4", "head": True},
    {"text": "✓ Read the importer", "tone": "dim"},
    {"text": "✓ parseCsv with a header row", "tone": "dim"},
    {"text": "✓ Tests for quoted fields", "tone": "dim"},
    {"text": "○ Wire it to the Import button"}]}
shells = {"id": "p2", "v": 1, "type": "panel.set", "panel": "shells", "title": "Shells", "rows": [
    {"text": "Shells", "head": True},
    {"text": "sh1 running 4m", "tone": "accent"},
    {"text": "  npm run dev", "tone": "muted"}]}
msgs = [{"id": "s", "v": 1, "type": "pi.session", "pi_session_id": sid, "session_file": "", "cwd": os.getcwd()},
        {"id": "t", "v": 1, "type": "pi.status", "agent": "working" if sid == "g1" else "idle",
         "waiting": sid == "n1", "blockers": []}]
if sid == "r1":
    msgs += [todos, shells]
deckhand = os.environ.get("DECKHAND_BIN")
if deckhand and os.environ.get("DECKHAND_SOCKET"):
    null = os.open(os.devnull, os.O_WRONLY)
    os.dup2(null, 1)
    os.dup2(null, 2)
    # --ctl reads DECKHAND_SOCKET/DECKHAND_TOKEN; a pi tab gets DECKHAND_SOCKET/DECKHAND_TOKEN
    os.environ["DECKHAND_SOCKET"] = os.environ["DECKHAND_SOCKET"]
    os.environ["DECKHAND_TOKEN"] = os.environ.get("DECKHAND_TOKEN", "")
    os.execv(deckhand, [deckhand, "--ctl", "--wait", "600000"] + [json.dumps(m) for m in msgs])
os.execvp("sleep", ["sleep", "600"])
