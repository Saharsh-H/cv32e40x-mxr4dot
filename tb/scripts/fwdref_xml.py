"""Signals used before their declaration in rtl/mxdotp/ (scan 1 of 2: Verilator's name resolution).

Verilator accepts a signal that is used before it is declared; stricter tools may warn,
error, or (in a port connection) create an implicit 1-bit net. Run before any synthesis
run, normally through fwdref_check.sh, which builds the XML and runs both scans:

  python3 scripts/fwdref_xml.py <top.xml>     (from verilator --xml-only of mxdotp_core_top)

For every module, each varref is compared with the var it resolves to (same name, same
file): a reference on an earlier line than the declaration is reported. Verilator has
already simplified some nets in the XML: an inlined reference can carry another line's
location, so a reference counts only if its name really appears on that line; and a use
that sits only inside a simplified net is missed (hence the second scan, fwdref_text.py).
Exit status: 0 none found, 1 found.
"""
import re
import sys
import xml.etree.ElementTree as ET


def code_lines(path, cache={}):
    """Source lines with comments and strings blanked (line numbers kept)."""
    if path not in cache:
        src = open(path).read()
        src = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), src, flags=re.S)
        src = re.sub(r"//[^\n]*", "", src)
        cache[path] = re.sub(r'"(?:\\.|[^"\\])*"', '""', src).split("\n")
    return cache[path]


def named_on_line(path, line, name):
    """True if the identifier really appears on that line (not as a .field)."""
    ls = code_lines(path)
    return 0 < line <= len(ls) and re.search(r"(?<![\w.$`])" + re.escape(name) + r"(?!\w)",
                                               ls[line - 1]) is not None


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = ET.parse(sys.argv[1]).getroot()
    files = {f.get("id"): f.get("filename") for f in root.iter("file")}

    def loc(e):
        l = e.get("loc")
        if not l:
            return None
        fid, line = l.split(",")[:2]
        return files.get(fid), int(line)

    found = set()
    for mod in root.iter("module"):
        decl = {}
        for v in mod.iter("var"):
            L, n = loc(v), v.get("name", "")
            if not L or n.startswith("__"):
                continue
            if n not in decl or L[1] < decl[n][1]:
                decl[n] = L
        first = {}
        for r in mod.iter("varref"):
            L, n = loc(r), r.get("name", "")
            if not L or n.startswith("__") or n not in decl or L[0] != decl[n][0]:
                continue
            if not named_on_line(L[0], L[1], n):   # attributed by Verilator's inlining
                continue
            if n not in first or L[1] < first[n][1]:
                first[n] = L
        for n, (f, use) in first.items():
            if use < decl[n][1] and "/rtl/mxdotp/" in f:
                found.add((f.split("/rtl/")[1], n, use, decl[n][1]))
    for f, n, use, d in sorted(found):
        print(f"{f}: {n}  first use line {use}, declared line {d}")
    print(f"fwdref_xml: {len(found)} forward references in rtl/mxdotp/")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
