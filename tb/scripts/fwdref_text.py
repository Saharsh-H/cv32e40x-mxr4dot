"""Signals used before their declaration in rtl/mxdotp/ (scan 2 of 2: source text).

Complements fwdref_xml.py (see there for why both exist). Normally run through
fwdref_check.sh:

  python3 scripts/fwdref_text.py <top.xml>    (from verilator --xml-only of mxdotp_core_top)

Declarations (name and line) come from the XML; uses are found in the source text of the
same module, with comments and strings blanked and `.name` (struct field, named port
connection) excluded. A use on an earlier line than the declaration is reported.

The XML has no entry for a net Verilator simplified away, so such a net's declaration is
invisible here. Those names are found by a plain text match on wire/logic/reg/bit/int/var
declarations and checked the same way, from their text declaration line. Exit status:
0 none found, 1 found.
"""
import re
import sys
import xml.etree.ElementTree as ET


def blank_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', src)


DECL_RE = re.compile(r"[ \t]*(?:wire|logic|reg|bit|int|integer|var)(?=[ \t\[])([^;=]*?)(?:=|;)")
PARAM_RE = re.compile(r"^\s*(?:localparam|parameter)\b")
KEYWORDS = {"signed", "unsigned", "logic", "wire", "reg", "bit"}


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = ET.parse(sys.argv[1]).getroot()
    files = {f.get("id"): f.get("filename") for f in root.iter("file")}
    found = set()
    for mod in root.iter("module"):
        fid, mline = mod.get("loc").split(",")[:2]
        f = files[fid]
        if "/rtl/mxdotp/" not in f:
            continue
        text = blank_comments(open(f).read())
        lines = text.split("\n")
        start = int(mline) - 1
        end = next(i for i in range(start, len(lines)) if re.search(r"\bendmodule\b", lines[i]))
        decl = {}
        for v in mod.iter("var"):
            l, n = v.get("loc"), v.get("name", "")
            if not l or n.startswith("__") or v.get("param") == "true":
                continue
            vf, vl = l.split(",")[:2]
            if files[vf] == f:
                decl[n] = min(decl.get(n, 10**9), int(vl))
        # nets absent from the XML: take their declaration line from the text
        # (module scope only: not inside function/task bodies or struct typedefs)
        depth_fn, depth_struct = 0, 0
        for i in range(start, end + 1):
            ln = lines[i]
            depth_fn += len(re.findall(r"\b(?:function|task)\b", ln)) - \
                        len(re.findall(r"\b(?:endfunction|endtask)\b", ln))
            if re.search(r"\btypedef\s+(?:struct|union)\b", ln):
                depth_struct += 1
            in_struct = depth_struct > 0
            if depth_struct and "}" in ln:
                depth_struct = 0
            m = DECL_RE.match(ln)
            if not m or depth_fn > 0 or in_struct or PARAM_RE.match(ln):
                continue
            names = re.sub(r"\[[^\]]*\]", "", m.group(1))
            # an identifier followed by another one is a type (wire mx_slot_e x), not a name
            for n in re.findall(r"(?<![\w.$`'])([A-Za-z_]\w*)\b(?!\s+[A-Za-z_])", names):
                if n not in KEYWORDS and n not in decl:
                    decl[n] = i + 1
        for n, d in decl.items():
            pat = re.compile(r"(?<![\w.$`])" + re.escape(n) + r"(?!\w)")
            for i in range(start, d - 1):
                if pat.search(lines[i]):
                    found.add((f.split("/rtl/")[1], n, i + 1, d))
                    break
    for f, n, use, d in sorted(found):
        print(f"{f}: {n}  first use line {use}, declared line {d}")
    print(f"fwdref_text: {len(found)} forward references in rtl/mxdotp/")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
