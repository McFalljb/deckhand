"""A small Odin source reader for scripts/core-move.py and scripts/core-move-verify.py.

Not a parser: it knows where comments and string literals are, the bracket depth at each
offset, and the top-level declarations of a file (name, kind, span), which is all the move needs.
"""
import re

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def code_mask(text):
    """A list of booleans, one per character: True where the character is code (not inside a
    comment or a string, rune or raw-string literal)."""
    return [k == "c" for k in code_kinds(text)]


def code_kinds(text):
    """One letter per character: "c" code, "s" inside a string, rune or raw-string literal,
    "m" inside a comment."""
    n = len(text)
    mask = ["c"] * n
    i = 0
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                mask[k] = "m"
            i = j
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            for k in range(i, j):
                mask[k] = "m"
            i = j
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            for k in range(i, j):
                mask[k] = "s"
            i = j
        elif c == "`":
            j = text.find("`", i + 1)
            j = n if j < 0 else j + 1
            for k in range(i, j):
                mask[k] = "s"
            i = j
        else:
            i += 1
    return mask


def line_starts(text):
    out = [0]
    for m in re.finditer("\n", text):
        out.append(m.end())
    return out


class Decl:
    def __init__(self, name, kind, start, end, head_start, depth, block):
        self.name = name  # the declared name
        self.kind = kind  # "type", "const", "proc", "var", "group"
        self.start = start  # offset of the declaration's first line (its name or attribute)
        self.end = end  # offset just past the declaration's last line (its newline included)
        self.head_start = head_start  # offset of its leading comment lines, if any (else start)
        self.depth = depth  # 0 at file level, 1 inside a top-level `foreign` or `when` block
        self.block = block  # the opener of that block ("foreign", "when") or None

    def __repr__(self):
        return f"Decl({self.name}, {self.kind}, {self.start}-{self.end}, d{self.depth})"


TYPE_HEADS = ("struct", "enum", "union", "bit_set", "bit_field", "distinct", "matrix", "#type",
              "#soa", "#simd", "map[", "[", "^", "typeid", "#sparse")
DECL_RE = re.compile(r"[ \t]*((?:@\([^\n]*?\)[ \t]*)*)([A-Za-z_]\w*(?:[ \t]*,[ \t]*[A-Za-z_]\w*)*)[ \t]*:")


def _kind(rhs, is_const):
    s = rhs.lstrip()
    if not is_const:
        return "var"
    if s.startswith("proc"):
        rest = s[4:].lstrip()
        if rest.startswith("{"):
            return "group"
        # skip a calling convention string, then the parameters, then look for a body
        if rest.startswith('"'):
            rest = rest[rest.index('"', 1) + 1:].lstrip()
        depth = 0
        for i, ch in enumerate(rest):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    tail = rest[i + 1:]
                    return "proc" if ("{" in tail or "---" in tail) else "type"
        return "proc"
    if s.startswith(TYPE_HEADS):
        # `[N]T{...}` / `[?]T{...}` is a constant array, `[N]T` alone a type
        if s.startswith("[") and "{" in s:
            return "const"
        return "type"
    if re.match(r"[A-Z]\w*(\.[A-Z]\w*)?\s*$", s):  # an alias of another type: `Foo :: Bar`
        return "type"
    return "const"


def top_decls(text, mask=None):
    """The file's top-level declarations, in order. Names declared together (`a, b: int`) give
    one Decl each, sharing the span."""
    kinds = code_kinds(text)
    if mask is None:
        mask = [k == "c" for k in kinds]
    n = len(text)
    starts = line_starts(text)
    # bracket depth at each line start, and which top-level block each depth-1 line is in
    depth = 0
    opener_stack = []
    line_depth = []
    line_block = []
    li = 0
    pending_opener = None
    pos = 0
    for li, ls in enumerate(starts):
        le = starts[li + 1] if li + 1 < len(starts) else n
        line_depth.append(depth)
        line_block.append(opener_stack[0] if opener_stack else None)
        line = text[ls:le]
        if depth == 0:
            stripped = line.lstrip()
            if re.match(r"(@\([^)]*\)\s*)*foreign\b", stripped) and not stripped.startswith("foreign import"):
                pending_opener = "foreign"
            elif stripped.startswith("when "):
                pending_opener = "when"
            else:
                pending_opener = "decl"
        for k in range(ls, le):
            if not mask[k]:
                continue
            ch = text[k]
            if ch in "{([":
                if depth == 0:
                    opener_stack = [pending_opener]
                depth += 1
            elif ch in "})]":
                depth -= 1
                if depth == 0:
                    opener_stack = []
    out = []
    li = 0
    nl = len(starts)
    while li < nl:
        ls = starts[li]
        le = starts[li + 1] if li + 1 < nl else n
        d = line_depth[li]
        blk = line_block[li]
        ok_depth = d == 0 or (d == 1 and blk in ("foreign", "when"))
        m = DECL_RE.match(text, ls, le) if ok_depth else None
        if not m or not mask[m.start(2)] or text[ls:le].lstrip().startswith(("package", "import", "case ")):
            li += 1
            continue
        after = text[m.end():le]
        is_const = after.startswith(":")
        if is_const:
            rhs = after[1:]
        elif after.lstrip().startswith("="):
            rhs = ""
        else:
            rhs = after
        if not is_const and not re.match(r"\s*[=A-Za-z_\[\^#(]", rhs if rhs else "="):
            li += 1
            continue
        kind = _kind(rhs, is_const)
        # the end: the first line after which the depth is back to d and the line does not end
        # with a continuation
        lj = li
        while lj + 1 < nl:
            nxt_d = line_depth[lj + 1]
            line = text[starts[lj]:starts[lj + 1]]
            # the line's code: a string stands as "x", a comment goes
            code = "".join(ch if kinds[starts[lj] + k] == "c" else "x" if kinds[starts[lj] + k] == "s" else ""
                           for k, ch in enumerate(line)).rstrip()
            if nxt_d <= d and not code.endswith((",", "|", "+", "=", "::", "&&", "||", "->")):
                break
            lj += 1
        end = starts[lj + 1] if lj + 1 < nl else n
        # attribute lines above (an attribute on its own line belongs to the decl below)
        start = ls
        hl = li
        while hl - 1 >= 0 and re.match(r"[ \t]*@\(", text[starts[hl - 1]:starts[hl]]) and line_depth[hl - 1] == d:
            hl -= 1
            start = starts[hl]
        head = start
        while hl - 1 >= 0 and text[starts[hl - 1]:starts[hl]].lstrip().startswith("//") and line_depth[hl - 1] == d:
            hl -= 1
            head = starts[hl]
        names = [x.strip() for x in m.group(2).split(",")]
        attrs = text[start:m.start(2)]
        for nm in names:
            dd = Decl(nm, kind, start, end, head, d, blk if d else None)
            dd.file_private = bool(re.search(r'@\(\s*private\s*=\s*"file"', attrs))
            out.append(dd)
        li = lj + 1
    return out


def imports(text):
    """[(alias or None, path, line start, line end)] of the file's import lines."""
    out = []
    for m in re.finditer(r'(?m)^import[ \t]+(?:([A-Za-z_]\w*)[ \t]+)?"([^"]+)"[^\n]*\n?', text):
        out.append((m.group(1), m.group(2), m.start(), m.end()))
    return out


def import_name(alias, path):
    if alias:
        return alias
    p = path.split(":", 1)[-1]
    return p.rstrip("/").split("/")[-1]
