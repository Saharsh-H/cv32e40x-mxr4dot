"""Pair [XIFMON] ISSUE/COMMIT/RESULT lines and print per-instruction timing.

usage (from tb/):  make full > full.log 2>&1
                   python3 scripts/xifmon_table.py full.log

Pairing: XIF ids are reused, so each COMMIT/RESULT is matched to the FIRST
still-unmatched ISSUE carrying the same id (FIFO per id), never by id alone.
REJECTED-ISSUE lines are counted separately; their (kill=1) commits are
consumed by a placeholder, and they never get a result.
"""
import re
import sys
from collections import defaultdict, deque

pat = re.compile(r'^\[XIFMON\] cyc=(\d+) (ISSUE|COMMIT|RESULT|REJECTED-ISSUE)\s+id=(\d+)(.*)$')
insts = []
open_commit = defaultdict(deque)
open_result = defaultdict(deque)
rejected = 0
for line in open(sys.argv[1]):
    m = pat.match(line.strip())
    if not m:
        continue
    cyc, kind, iid, rest = int(m[1]), m[2], int(m[3]), m[4]
    if kind == 'REJECTED-ISSUE':
        # Rejected offloads (e.g. the core offering its CSR instructions) still
        # get a commit (kill=1) and never a result: queue a placeholder so that
        # commit is consumed in order and does not pair with a real issue.
        rejected += 1
        open_commit[iid].append(dict(rejected=True))
    elif kind == 'ISSUE':
        name = rest.split()[0]
        rd = re.search(r'rd=(x\d+)', rest)[1]
        rec = dict(n=len(insts), id=iid, name=name, rd=rd, issue=cyc, commit=None, result=None, kill=None)
        insts.append(rec)
        open_commit[iid].append(rec)
        open_result[iid].append(rec)
    elif kind == 'COMMIT':
        rec = open_commit[iid].popleft()
        rec['commit'] = cyc
        rec['kill'] = re.search(r'kill=(\d)', rest)[1]
    else:
        rec = open_result[iid].popleft()
        rec['result'] = cyc

left = sum(len(q) for q in open_result.values())
print(f'issues={len(insts)} rejected={rejected} unmatched_results={left}')
print('n  id  instr                rd   issue commit result  iss->com com->res iss->res  prev_issue_gap')
prev = None
for r in insts:
    gap = '' if prev is None else r['issue'] - prev['issue']
    print(f"{r['n']:<2} {r['id']:<3} {r['name']:<20} {r['rd']:<4} {r['issue']:<5} {r['commit']:<6} {r['result']:<6}  "
          f"{r['commit']-r['issue']:<7} {r['result']-r['commit']:<7} {r['result']-r['issue']:<8}  {gap}  kill={r['kill']}")
    prev = r
