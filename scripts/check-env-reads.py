#!/usr/bin/env python3
"""Every environment read in what Deckhand ships names its variable with a string literal from the
list below (docs/plans/background-core.md §5.3, "A genuine binary under attacker config";
src/test_hooks.odin). A test or development knob goes through hook_env() instead, which a release
build compiles out; a name built at run time ("DECKHAND_%s") could not be checked at all, so it is
refused here. scripts/check-release-build.sh runs this (so release.sh does); ./build.sh test too.

Usage: scripts/check-env-reads.py [--root DIR]   (exit 1 and one line per bad read; DIR: tests)
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
if len(sys.argv) == 3 and sys.argv[1] == "--root":
    ROOT = pathlib.Path(sys.argv[2]).resolve()

# Read by Deckhand, its CLI or its holder in every build: user and system environment, the user's
# own settings, and what Deckhand itself sets for its tabs (src/test_hooks.odin says why the
# DECKHAND_ ones are not hooks; scripts/check-release-build.sh ALLOWED is the binary-side list).
KNOWN = {
    "HOME", "TMPDIR", "SHELL", "PATH", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "XDG_DATA_HOME",
    "PI_CODING_AGENT_DIR", "CLAUDE_CONFIG_DIR", "PI_KIT_NOTES_DIR",
    "CLAUDE_CODE_PROJECT_DIR_NAME",  # Claude Code's own (the user's env): how it names project folders
    "CFFIXED_USER_HOME",  # browser.odin: only a test-mode check that the scene set it
    "DECKHAND_SOCKET", "DECKHAND_TOKEN", "DECKHAND_CLAUDE_TOKEN", "DECKHAND_SHOTS_DIR",  # the CLIs' transport
    "DECKHAND_GUI_LAUNCH", "DECKHAND_CEF_SHARED_TEXTURE",  # the user's workarounds
    # their old names, read after the new ones (src/env_names.odin: the rename's fallback)
    "PI_DESK_SOCKET", "PI_DESK_TOKEN", "PI_DESK_CLAUDE_TOKEN", "PI_DESK_SHOTS_DIR",
    "PI_DESK_GUI_LAUNCH", "PI_DESK_CEF_SHARED_TEXTURE",
}
# Test and development knobs read outside hook_env, each compiled out of release builds where it
# is read (the check on the release binary forbids the name too).
HOOK_ONLY = {
    "DECKHAND_CEF_SPARE": "src/native/cef_macos.m",  # #ifndef DH_RELEASE
    "DECKHAND_CEF_NETLOG": "src/native/cef_macos.m",  # #ifndef DH_RELEASE
    "DECKHAND_HOLDER_HOOKS": "src/holder/keeper.odin",  # when TEST_HOOKS (holder)
}
# A read whose argument is not a literal is allowed only with a marker comment on its line,
# `// env-read-ok: <why>` (each reviewed: hook_env itself, a loop over a literal list, a wrapper
# whose callers are checked here).
MARKER = "env-read-ok:"
# the shipped pi integration: what it reads of Deckhand's (deckhandEnv / envToken) and pi-kit's
TS_KNOWN = {
    "DECKHAND_SOCKET", "DECKHAND_TOKEN", "DECKHAND_CONTROL_TOKEN", "DECKHAND_SHOTS_DIR",
    "PI_CODING_AGENT_DIR", "PI_KIT_NOTES_DIR", "PI_KIT_READONLY", "PI_SUBAGENT_CHILD",
    "PI_KIT_SHELL_LOG_CAP", "PI_KIT_SHELL_CHECKIN_MS", "PI_KIT_NOTES_REMIND_PERCENT",
}

CALL = re.compile(r"\b(?:os\.|c\.|posix\.)?(get_env|lookup_env|getenv)\s*\(\s*([^,)]*)|\b(env_lookup)\s*\([^,]*,\s*([^,)]*)")
TS_CALL = re.compile(r"\b(deckhandEnv|envToken)\s*\(\s*([^,)]*)|process\.env\.([A-Za-z_][A-Za-z0-9_]*)|process\.env\[\s*([^\]]*)\]")
LIT = re.compile(r'^"([A-Za-z_][A-Za-z0-9_]*)"$')


def sources():
    for base, pats in (("src", ("*.odin", "*.m", "*.c", "*.h", "*.inc")), ("tools", ("*.odin",))):
        for pat in pats:
            for p in sorted((ROOT / base).rglob(pat)):
                if p.name.endswith("_test.odin") or "/tests/" in str(p):
                    continue
                yield p


def split_comment(line, quotes):
    """(code, comment): the line cut at its first // outside a string (quotes: the string quote
    characters of the language; a backtick string has no escapes)."""
    q = None
    i = 0
    while i < len(line):
        ch = line[i]
        if q:
            if ch == "\\" and q != "`":
                i += 2
                continue
            if ch == q:
                q = None
        elif ch in quotes:
            q = ch
        elif line.startswith("//", i):
            return line[:i], line[i:]
        i += 1
    return line, ""


DECL = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\s*:")


def main():
    bad = []
    for p in sources():
        rel = str(p.relative_to(ROOT))
        for n, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
            code, comment = split_comment(line, "\"'`")
            marked = MARKER in comment
            for m in CALL.finditer(code):
                fn, arg = (m.group(1), m.group(2)) if m.group(1) else (m.group(3), m.group(4))
                arg = arg.strip()
                if arg == "" or DECL.match(arg):
                    # a declaration (proc(k: string)) says no name; else the name is on another
                    # line, where it can't be checked
                    if "proc" in code:
                        continue
                    bad.append(f"{rel}:{n}: {fn}(: the name is not on the call's line")
                    continue
                lit = LIT.match(arg)
                if lit:
                    name = lit.group(1)
                    if name in KNOWN:
                        continue
                    if HOOK_ONLY.get(name) == rel:
                        continue
                    bad.append(f"{rel}:{n}: {fn}(\"{name}\"): not a known variable (a test knob? read it with hook_env)")
                elif not marked:
                    bad.append(f"{rel}:{n}: {fn}({arg}): the name is not a string literal (or mark the line: // {MARKER} why)")
    for p in sorted((ROOT / "integrations").rglob("*.ts")):
        if "/test/" in str(p) or "node_modules" in str(p) or p.name.endswith(".test.ts"):
            continue
        rel = str(p.relative_to(ROOT))
        for n, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
            code, comment = split_comment(line, "\"'`")
            marked = MARKER in comment
            for m in TS_CALL.finditer(code):
                arg = (m.group(2) or m.group(4) or "").strip()
                name = m.group(3)
                if name is None:
                    if arg == "" or DECL.match(arg):
                        if "function" in code or "=>" in code:
                            continue  # declarations
                        bad.append(f"{rel}:{n}: env read: the name is not on the call's line")
                        continue
                    lit = re.match(r'^["\']([A-Za-z_][A-Za-z0-9_]*)["\']$', arg)
                    if not lit:
                        if marked:
                            continue
                        bad.append(f"{rel}:{n}: env read ({arg}): the name is not a string literal (or mark the line: // {MARKER} why)")
                        continue
                    name = lit.group(1)
                if name not in TS_KNOWN:
                    bad.append(f"{rel}:{n}: env read {name}: not a known variable (a test knob in shipped code?)")
    for b in bad:
        print("check-env-reads:", b, file=sys.stderr)
    if bad:
        return 1
    print("check-env-reads: every environment read names a known variable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
