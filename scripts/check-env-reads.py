#!/usr/bin/env python3
"""Every environment read in what Deckhand ships names its variable with a string literal from the
list below (docs/plans/background-core.md §5.3, "A genuine binary under attacker config";
src/core/test_hooks.odin). A test or development knob goes through hook_env() instead, which a release
build compiles out; a name built at run time ("DECKHAND_%s") could not be checked at all, so it is
refused here. A name in a same-file string constant (Odin `X :: "NAME"`, TypeScript
`const X = "NAME"`) counts as written there: the constant's value is checked. Any other way to the
environment is refused unless its line is marked (MARKER): TypeScript's process.env anywhere but
`.NAME` or `[...]` (an alias such as `const env = process.env`, then `env[X]`; a spread, a
destructuring, Object.keys), Objective-C's NSProcessInfo environment by anything but a literal.
scripts/check-release-build.sh runs this (so release.sh does); ./build.sh test too, with its own
test (tests/check-env-reads-test.sh).

Usage: scripts/check-env-reads.py [--root DIR]   (exit 1 and one line per bad read; DIR: tests)
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
if len(sys.argv) == 3 and sys.argv[1] == "--root":
    ROOT = pathlib.Path(sys.argv[2]).resolve()

# Read by Deckhand, its CLI or its holder in every build: user and system environment, the user's
# own settings, and what Deckhand itself sets for its tabs (src/core/test_hooks.odin says why the
# DECKHAND_ ones are not hooks; scripts/check-release-build.sh ALLOWED is the binary-side list).
KNOWN = {
    "HOME", "TMPDIR", "SHELL", "PATH", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "XDG_DATA_HOME",
    "PI_CODING_AGENT_DIR", "CLAUDE_CONFIG_DIR", "PI_KIT_NOTES_DIR",
    "CLAUDE_CODE_PROJECT_DIR_NAME",  # Claude Code's own (the user's env): how it names project folders
    "CODEX_HOME",  # Codex's own (the user's env, as tabs get it): its folder, which the credential guard refuses (codex.odin)
    "NVM_DIR", "FNM_DIR",  # nvm's and fnm's folders as tabs get them: harness binaries looked for there by stat (harness.odin)
    "CFFIXED_USER_HOME",  # browser.odin: only a test-mode check that the scene set it
    "DECKHAND_SOCKET", "DECKHAND_TOKEN", "DECKHAND_CLAUDE_TOKEN", "DECKHAND_SHOTS_DIR",  # the CLIs' transport
    "DECKHAND_GUI_LAUNCH", "DECKHAND_CEF_SHARED_TEXTURE",  # the user's workarounds
    "_DECKHAND_RESPONSIBLE",  # the holder's own TCC re-exec marker (src/holder/sys_darwin.odin; check-release-build.sh)
    # their old names, read after the new ones (src/core/env_names.odin: the rename's fallback)
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
# process.env as a whole (or process["env"], globalThis.process.env): an alias, a spread, a
# destructuring, Object.keys... (what TS_CALL takes is left out: `.NAME` and `[...]`)
TS_WHOLE = re.compile(r"\bprocess\s*(?:\.\s*env\b(?!\s*(?:\.\s*[A-Za-z_]|\[))|\[\s*[\"'`]env[\"'`]\s*\])")
# Objective-C: NSProcessInfo's environment dictionary, by key or as a whole
OBJC_ENV = re.compile(r"\benvironment\s*\]|\.environment\b")
OBJC_KEY = re.compile(r"(?:\benvironment\s*\]|\.environment)\s*(?:\[\s*|\s+objectForKey:\s*)@\"([A-Za-z_][A-Za-z0-9_]*)\"")
LIT = re.compile(r'^"([A-Za-z_][A-Za-z0-9_]*)"$')
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# same-file string constants (one per line, at any indent): Odin's `X :: "NAME"`, TypeScript's
# `const X = "NAME"` (export, `as const` too)
ODIN_CONST = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*::\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*(?://.*)?$')
TS_CONST = re.compile(r'^\s*(?:export\s+)?const\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*(?::\s*string\s*)?=\s*["\'`]([A-Za-z_][A-Za-z0-9_]*)["\'`]\s*(?:as\s+const\s*)?;?\s*(?://.*)?$')


def constants(lines, pattern):
    """name -> value of the file's string constants; a name defined twice (shadowed in another
    scope, perhaps) is left out: it could be either."""
    out, twice = {}, set()
    for line in lines:
        m = pattern.match(line)
        if not m:
            continue
        if m.group(1) in out and out[m.group(1)] != m.group(2):
            twice.add(m.group(1))
        out[m.group(1)] = m.group(2)
    for k in twice:
        del out[k]
    return out


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


def strip_blocks(lines, quotes):
    """The lines with /* ... */ comments blanked (they may span lines), strings kept."""
    out, inside = [], False
    for line in lines:
        b, q, i = [], None, 0
        while i < len(line):
            if inside:
                if line.startswith("*/", i):
                    inside = False
                    i += 2
                else:
                    i += 1
                continue
            ch = line[i]
            if q:
                b.append(ch)
                if ch == "\\" and q != "`" and i + 1 < len(line):
                    b.append(line[i + 1])
                    i += 2
                    continue
                if ch == q:
                    q = None
            elif ch in quotes:
                q = ch
                b.append(ch)
            elif line.startswith("//", i):
                b.append(line[i:])
                break
            elif line.startswith("/*", i):
                inside = True
                i += 2
                continue
            else:
                b.append(ch)
            i += 1
        out.append("".join(b))
    return out


DECL = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\s*:")


def main():
    bad = []
    for p in sources():
        rel = str(p.relative_to(ROOT))
        lines = strip_blocks(p.read_text(errors="replace").splitlines(), "\"'`" if p.suffix == ".odin" else "\"'")
        consts = constants(lines, ODIN_CONST) if p.suffix == ".odin" else {}
        for n, line in enumerate(lines, 1):
            code, comment = split_comment(line, "\"'`")
            marked = MARKER in comment
            if p.suffix == ".m" and OBJC_ENV.search(code):
                keys = OBJC_KEY.findall(code)
                if len(keys) != len(OBJC_ENV.findall(code)) and not marked:
                    bad.append(f"{rel}:{n}: NSProcessInfo environment: read by a literal key (@\"NAME\") only (or mark the line: // {MARKER} why)")
                for name in keys:
                    if name not in KNOWN and HOOK_ONLY.get(name) != rel:
                        bad.append(f"{rel}:{n}: environment[@\"{name}\"]: not a known variable (a test knob? read it with hook_env)")
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
                if not lit and IDENT.match(arg) and arg in consts:
                    lit = re.match(r"(.*)", consts[arg])  # a constant: its value is the name read
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
        lines = strip_blocks(p.read_text(errors="replace").splitlines(), "\"'`")
        consts = constants(lines, TS_CONST)
        for n, line in enumerate(lines, 1):
            code, comment = split_comment(line, "\"'`")
            marked = MARKER in comment
            if TS_WHOLE.search(code) and not marked:
                bad.append(f"{rel}:{n}: process.env as a whole (an alias, spread, destructuring or listing): read it by name, process.env.NAME (or mark the line: // {MARKER} why)")
            for m in TS_CALL.finditer(code):
                arg = (m.group(2) or m.group(4) or "").strip()
                name = m.group(3)
                if name is None:
                    if arg == "" or DECL.match(arg):
                        if "function" in code or "=>" in code:
                            continue  # declarations
                        bad.append(f"{rel}:{n}: env read: the name is not on the call's line")
                        continue
                    lit = re.match(r'^["\'`]([A-Za-z_][A-Za-z0-9_]*)["\'`]$', arg)
                    if not lit and IDENT.match(arg) and arg in consts:
                        lit = re.match(r"(.*)", consts[arg])  # a constant: its value is the name read
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
