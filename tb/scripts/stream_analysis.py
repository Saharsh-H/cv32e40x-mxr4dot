"""Per-stream rates and data checks for the make-stream [XIFMON] log.

usage (from tb/):  make stream > stream.log 2>&1
                   python3 scripts/stream_analysis.py stream.log

Pairing: COMMIT/RESULT go to the first unmatched ISSUE with the same id (FIFO
per id; ids wrap at 16). Streams are assigned by issue order, matching the
program order in instr_rom.sv's MX_STREAM_TEST block: S1, S2, S3, S5, S4, S6.
Steady state: drop the first DROP results of a stream, then
cycles/instr = (last result - first kept result) / (number kept - 1).
For the residue pairs (S4) the rate is also given per pair, from the mxfinal
results alone (one mxfinal completes each pair).
"""
import re
import sys
from collections import defaultdict, deque

DROP = 3
EXPECT = {'S1': [0x41800000] * 16, 'S2': [0x41000000] * 16, 'S3': [0x41EF0000] * 16,
          'S5': [0x41800000, 0x42000000, 0x42400000, 0x42800000, 0x42A00000, 0x42C00000,
                 0x42E00000, 0x43000000, 0x43100000, 0x43200000, 0x43300000, 0x43400000,
                 0x43500000, 0x43600000, 0x43700000, 0x43800000],
          'S4': [0x41C00000] * 16,  # mxfinal results; mxresdot results carry we=0, data 0
          'S6': [0x41C00000] * 5}
ELEMS = {'S1': 16, 'S2': 8, 'S3': 16, 'S5': 16, 'S4': 8, 'S6': 8}  # per instruction (pair = 16 / 2 instr)
ORDER = [('S1', 16), ('S2', 16), ('S3', 16), ('S5', 16), ('S4', 32), ('S6', 10)]

pat = re.compile(r'^\[XIFMON\] cyc=(\d+) (ISSUE|COMMIT|RESULT|REJECTED-ISSUE)\s+id=(\d+)(.*)$')
insts, oc, orr = [], defaultdict(deque), defaultdict(deque)
for line in open(sys.argv[1]):
    m = pat.match(line.strip())
    if not m:
        continue
    cyc, kind, iid, rest = int(m[1]), m[2], int(m[3]), m[4]
    if kind == 'REJECTED-ISSUE':
        print('REJECTED ISSUE seen:', line.strip()); continue
    if kind == 'ISSUE':
        r = dict(name=rest.split()[0], issue=cyc, commit=None, result=None, data=None, we=None)
        insts.append(r); oc[iid].append(r); orr[iid].append(r)
    elif kind == 'COMMIT':
        oc[iid].popleft()['commit'] = cyc
    else:
        r = orr[iid].popleft(); r['result'] = cyc
        r['data'] = int(re.search(r'data=0x([0-9a-f]+)', rest)[1], 16)
        r['we'] = int(re.search(r'we=(\d)', rest)[1])

i = 0
for sname, n in ORDER:
    rows = insts[i:i + n]; i += n
    print(f'\n== {sname}: {len(rows)} issued of {n}')
    if not rows:
        continue
    names = sorted(set(r['name'] for r in rows))
    done = [r for r in rows if r['result'] is not None]
    print(f'   instr={names} completed={len(done)} committed={sum(r["commit"] is not None for r in rows)}')
    # data check
    if sname in ('S4', 'S6'):
        fin = [r for r in done if r['name'] == 'mxfinal']
        dots = [r for r in done if r['name'] == 'mxresdot']
        bad = [r for r in fin if r['data'] != 0x41C00000] + [r for r in dots if r['we'] != 0]
        print(f'   data: mxfinal {len(fin)} checked, mxresdot {len(dots)} checked (we=0), mismatches={len(bad)}')
    else:
        bad = [(k, hex(r['data'])) for k, r in enumerate(done) if r['data'] != EXPECT[sname][k]]
        print(f'   data: {len(done)} checked vs golden, mismatches={len(bad)} {bad[:3]}')
    res = [r['result'] for r in done]
    gaps = [b - a for a, b in zip(res, res[1:])]
    iss = [r['issue'] for r in rows]
    print(f'   issue cycles : {iss}')
    print(f'   commit cycles: {[r["commit"] for r in rows]}')
    print(f'   result cycles: {res}')
    print(f'   result gaps  : {gaps}')
    print(f'   issue->result: {[r["result"] - r["issue"] for r in done]}')
    if len(done) == n and n - DROP >= 2:
        kept = res[DROP:]
        cpi = (kept[-1] - kept[0]) / (len(kept) - 1)
        print(f'   steady state (drop first {DROP}): {cpi:.3f} cycles/instr, '
              f'{ELEMS[sname] / cpi:.3f} elements/cycle')
        tot = (res[-1] - iss[0])
        print(f'   whole stream: first issue {iss[0]} -> last result {res[-1]} = {tot} cycles for {n} instr')
    if sname == 'S4' and len(done) == n:
        fres = [r['result'] for r in done if r['name'] == 'mxfinal']
        kept = fres[DROP:]
        cpp = (kept[-1] - kept[0]) / (len(kept) - 1)
        print(f'   mxfinal result gaps: {[b - a for a, b in zip(fres, fres[1:])]}')
        print(f'   per pair (drop first {DROP} pairs): {cpp:.3f} cycles/pair, {16 / cpp:.3f} elements/cycle')
