"""A stand-in for the Linux core's release tarball (scripts/pack-linux.sh's layout), for
tests/scripts/release-checks.sh: the three binaries are copies of BIN (a binary with no Deckhand
names), plus the integrations' marker files. KIND bends it the ways scripts/release-linux.sh must
refuse:
  good      the layout
  dotdot    a member TOP/../escape
  abs       a member /tmp/escape
  symlink   TOP/link -> /etc/passwd
  hardlink  TOP/hard, a hard link to TOP/deckhand
  outside   a member beside TOP/
  missing   no TOP/deckhand-core
  hook      deckhand-core-serve holds DECKHAND_SCRIPT (a test hook's name)
Usage: python3 -I tests/scripts/release-fixture.py OUT.tar.gz TOP KIND BIN
"""
import io
import sys
import tarfile


def main():
    out, top, kind, binpath = sys.argv[1:5]
    with open(binpath, "rb") as f:
        binary = f.read()
    with tarfile.open(out, "w:gz", format=tarfile.GNU_FORMAT) as t:

        def add(name, data=None, mode=0o644, kind_=tarfile.REGTYPE, link=""):
            i = tarfile.TarInfo(name)
            i.uid = i.gid = 0
            i.mode = mode
            i.type = kind_
            i.linkname = link
            i.mtime = 0
            if data is not None:
                i.size = len(data)
                t.addfile(i, io.BytesIO(data))
            else:
                t.addfile(i)

        add(top, mode=0o755, kind_=tarfile.DIRTYPE)
        serve = binary + (b"\x01DECKHAND_SCRIPT\x01" if kind == "hook" else b"")
        add(top + "/deckhand-core-serve", serve, 0o755)
        if kind != "missing":
            add(top + "/deckhand-core", binary, 0o755)
        add(top + "/deckhand", binary, 0o755)
        add(top + "/LICENSE", b"license\n")
        add(top + "/pi", mode=0o755, kind_=tarfile.DIRTYPE)
        add(top + "/pi/extensions.json", b"{}\n")
        add(top + "/claude-code", mode=0o755, kind_=tarfile.DIRTYPE)
        add(top + "/claude-code/.claude-plugin", mode=0o755, kind_=tarfile.DIRTYPE)
        add(top + "/claude-code/.claude-plugin/plugin.json", b"{}\n")
        if kind == "dotdot":
            add(top + "/../escape", b"x\n")
        elif kind == "abs":
            add("/tmp/escape", b"x\n")
        elif kind == "symlink":
            add(top + "/link", kind_=tarfile.SYMTYPE, link="/etc/passwd", mode=0o777)
        elif kind == "hardlink":
            add(top + "/hard", kind_=tarfile.LNKTYPE, link=top + "/deckhand")
        elif kind == "outside":
            add("other/file", b"x\n")


main()
