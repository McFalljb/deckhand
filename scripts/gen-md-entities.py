#!/usr/bin/env python3
# Regenerates the named character reference table in src/markdown_entities.odin
# (MD_ENTITIES) from Python's html.entities.html5, the WHATWG table: the names
# that end in ';', sorted by bytes. Invisible and combining characters are
# written as \u escapes. Usage (from the repository root):
#   python3 -I scripts/gen-md-entities.py
import html.entities as h
import unicodedata as u

PATH = "src/markdown_entities.odin"
HEAD = "MD_ENTITIES := [?]Md_Entity {\n"


def lit(v):
    out = ""
    for ch in v:
        if ch == '"':
            out += '\\"'
        elif ch == "\\":
            out += "\\\\"
        elif u.category(ch)[0] in "CZM":
            o = ord(ch)
            out += f"\\u{o:04X}" if o <= 0xFFFF else f"\\U{o:08X}"
        else:
            out += ch
    return '"' + out + '"'


names = sorted(((k[:-1], v) for k, v in h.html5.items() if k.endswith(";")), key=lambda kv: kv[0].encode())
lines, cur = [], "\t"
for n, v in names:
    item = '{"%s", %s},' % (n, lit(v))
    if len(cur) + len(item) + 1 > 100 and cur.strip():
        lines.append(cur.rstrip())
        cur = "\t"
    cur += item + " "
lines.append(cur.rstrip())

src = open(PATH, encoding="utf-8").read()
start = src.index(HEAD) + len(HEAD)
end = src.index("\n}\n", start)
src = src[:start] + "\n".join(lines) + src[end:]
open(PATH, "w", encoding="utf-8").write(src)
print(f"{PATH}: {len(names)} names")
