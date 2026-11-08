#!/usr/bin/env python3
"""A demo pi for the README screenshot (tests/scripts/readme-shot.sh). Never a real pi.

It draws a static, pi-like conversation about the fake recipe-box project, then
plays the pi integration's bridge over Deckhand's socket (deckhand --ctl with the tab's
single-use DECKHAND_TOKEN): pi.session, pi.status idle, and a todos panel. Every
word on screen is made up for the picture.
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
foot_l = "~/code/recipe-box (main)"
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
        {"id": "t", "v": 1, "type": "pi.status", "agent": "idle", "waiting": False, "blockers": []}]
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
