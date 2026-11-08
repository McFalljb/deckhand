#!/usr/bin/env python3
"""Every environment read in what Deckhand ships names its variable with a string literal from the
list below (docs/plans/background-core.md §5.3, "A genuine binary under attacker config";
src/test_hooks.odin). A test or development knob goes through hook_env() instead, which a release
build compiles out; a name built at run time ("PI_DESK_%s") could not be checked at all, so it is
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
# PI_DESK_ ones are not hooks; scripts/check-release-build.sh ALLOWED is the binary-side list).
KNOWN = {
    "HOME", "TMPDIR", "SHELL", "PATH", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "XDG_DATA_HOME",
    "PI_CODING_AGENT_DIR", "CLAUDE_CONFIG_DIR", "PI_KIT_NOTES_DIR",
    "CFFIXED_USER_HOME",  # browser.odin: only a test-mode check that the scene set it
    "PI_DESK_SOCKET", "PI_DESK_TOKEN", "PI_DESK_CLAUDE_TOKEN", "PI_DESK_SHOTS_DIR",  # the CLIs' transport
    "PI_DESK_GUI_LAUNCH", "PI_DESK_CEF_SHARED_TEXTURE",  # the user's workarounds
}
# Test and development knobs read outside hook_env, each compiled out of release builds where it
# is read (the check on the release binary forbids the name too).
HOOK_ONLY = {
    "PI_DESK_CEF_SPARE": "src/native/cef_macos.m",  # #ifndef PD_RELEASE
    "PI_DESK_CEF_NETLOG": "src/native/cef_macos.m",  # #ifndef PD_RELEASE
    "DECKHAND_HOLDER_HOOKS": "src/holder/keeper.odin",  # when TEST_HOOKS (holder)
}
# The few reads whose argument is not a literal, each reviewed: (file, the argument as written).
NON_LITERAL = {
    ("src/test_hooks.odin", "HOOK_ENV[h]"),  # hook_env / hook_lookup themselves
    ("src/jobs.odin", "k"),  # for k in a literal list: HOME USER LANG TMPDIR PI_CODING_AGENT_DIR
    ("src/holder/spawn.odin", "RESPONSIBLE_ENV"),  # a constant (the TCC re-exec marker)
    ("tools/pi-desk-cli/main.odin", "k"),  # the CLI's getenv wrapper: its callers are checked (c.getenv)
    ("integrations/pi/lib/protocol.ts", "name"),  # deckhandEnv itself, over DECKHAND_* only
    ("integrations/pi/lib/protocol.ts", "env"),  # envToken: its callers are checked
    ("integrations/pi/extensions/desk/index.ts", "ENV"),  # const ENV = "DECKHAND_CONTROL_TOKEN"
}
JOBS_LIST = {"USER", "LANG"}  # src/jobs.odin's literal list (passed on to job runs)
# the shipped pi integration: what it reads of Deckhand's (deckhandEnv / envToken) and pi-kit's
TS_KNOWN = {
    "DECKHAND_SOCKET", "DECKHAND_TOKEN", "DECKHAND_CONTROL_TOKEN", "DECKHAND_SHOTS_DIR",
    "PI_CODING_AGENT_DIR", "PI_KIT_NOTES_DIR", "PI_KIT_READONLY", "PI_SUBAGENT_CHILD",
    "PI_KIT_SHELL_LOG_CAP", "PI_KIT_SHELL_CHECKIN_MS", "PI_KIT_NOTES_REMIND_PERCENT",
}

CALL = re.compile(r"\b(?:os\.|c\.|posix\.)?(get_env|lookup_env|getenv)\s*\(\s*([^,)]*)")
TS_CALL = re.compile(r"\b(deckhandEnv|envToken)\s*\(\s*([^,)]*)|process\.env\.([A-Za-z_][A-Za-z0-9_]*)|process\.env\[\s*([^\]]*)\]")
LIT = re.compile(r'^"([A-Za-z_][A-Za-z0-9_]*)"$')


def sources():
    for base, pats in (("src", ("*.odin", "*.m", "*.c", "*.h", "*.inc")), ("tools", ("*.odin",))):
        for pat in pats:
            for p in sorted((ROOT / base).rglob(pat)):
                if p.name.endswith("_test.odin") or "/tests/" in str(p):
                    continue
                yield p


def strip_comment(line):
    i = line.find("//")
    return line if i < 0 else line[:i]


def main():
    bad = []
    for p in sources():
        rel = str(p.relative_to(ROOT))
        for n, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
            code = strip_comment(line)
            for m in CALL.finditer(code):
                fn, arg = m.group(1), m.group(2).strip()
                if arg.startswith("k: string") or arg.startswith("name: string") or arg == "":
                    continue  # a declaration (the CLI's getenv field), not a read
                lit = LIT.match(arg)
                if lit:
                    name = lit.group(1)
                    if name in KNOWN or (rel == "src/jobs.odin" and name in JOBS_LIST):
                        continue
                    if HOOK_ONLY.get(name) == rel:
                        continue
                    bad.append(f"{rel}:{n}: {fn}(\"{name}\"): not a known variable (a test knob? read it with hook_env)")
                elif (rel, arg) not in NON_LITERAL:
                    bad.append(f"{rel}:{n}: {fn}({arg}): the name is not a string literal")
    for p in sorted((ROOT / "integrations").rglob("*.ts")):
        if "/test/" in str(p) or "node_modules" in str(p) or p.name.endswith(".test.ts"):
            continue
        rel = str(p.relative_to(ROOT))
        for n, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
            code = strip_comment(line)
            for m in TS_CALL.finditer(code):
                arg = (m.group(2) or m.group(4) or "").strip()
                name = m.group(3)
                if name is None:
                    if arg.startswith("name: string") or arg.startswith("env: string"):
                        continue  # declarations
                    lit = re.match(r'^["\']([A-Za-z_][A-Za-z0-9_]*)["\']$', arg)
                    if not lit:
                        if (rel, arg) in NON_LITERAL:
                            continue
                        bad.append(f"{rel}:{n}: env read ({arg}): the name is not a string literal")
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
