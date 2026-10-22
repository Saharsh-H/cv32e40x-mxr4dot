"""Checker for make q10 (tb/Makefile): sw/q10_isolation runs, one log per data-port setting.

Each run must exit 0 (PROGRAM EXIT code=0) and grant exactly one data access per load in
case A (MARK 1..2: lw;lw x3) and case B (MARK 3..4: mxfused;lw;lw x3). Grants come from
mem_model.sv +gcount: "[GNT] mark=<id> data_grants=<n>", n including the MARK store's own
grant, so the loads between MARK k and MARK k+1 = n(k+1) - n(k) - 1.

usage: python3 q10_check.py <log> [<log> ...]     exit 0 = all pass
"""
import os, re, sys

LOADS_PER_CASE = 6

fail = 0
print(f'{"setting":10s} {"exit":>6s} {"A grants":>9s} {"B grants":>9s}  verdict')
for path in sys.argv[1:]:
    txt = open(path).read()
    m = re.search(r'PROGRAM EXIT code=(\d+)', txt)
    code = int(m.group(1)) if m else None
    g = {int(a): int(b) for a, b in re.findall(r'\[GNT\] mark=(\d+) data_grants=(\d+)', txt)}
    a = g[2] - g[1] - 1 if 1 in g and 2 in g else None
    b = g[4] - g[3] - 1 if 3 in g and 4 in g else None
    ok = code == 0 and a == LOADS_PER_CASE and b == LOADS_PER_CASE
    why = [] if ok else [w for w, bad in (('no exit/hang' if code is None else f'exit {code}', code != 0),
                                         (f'A {a} != {LOADS_PER_CASE}', a != LOADS_PER_CASE),
                                         (f'B {b} != {LOADS_PER_CASE}', b != LOADS_PER_CASE)) if bad]
    fail += not ok
    name = os.path.basename(path).removesuffix('.log')
    print(f'{name:10s} {str(code):>6s} {str(a):>9s} {str(b):>9s}  {"PASS" if ok else "FAIL: " + ", ".join(why)}')
print(f'q10: {len(sys.argv) - 1 - fail} pass, {fail} fail')
sys.exit(1 if fail else 0)
