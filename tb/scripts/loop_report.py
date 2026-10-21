"""Timing table for a make-loop program log (task 3).

usage (from tb/):
  make loop PROG=mxfp4 > mxfp4.log 2>&1
  python3 scripts/loop_report.py mxfp4.log --k 4096 --mx 10:256,20:256

The program brackets each region with MARK id / MARK id+1 and then PUTHEXes
0xC0DE00<id>, the mcycle delta and the minstret delta (CSRs read just outside
the MARKs). Region 90 is empty: its three numbers are the fixed overhead of
the bracket and are subtracted from every other region ("net").

Columns:
  cycles       net MARK delta (testbench cycle counter) - the primary timing
  mcycle       net mcycle delta - cross-check; mcycle - cycles is printed
  instret      net minstret delta (retired instructions, MX ones included)
  host/MX      (instret - MX) / MX   host (non-MX) instructions per MX instruction
  host/elem    (instret - MX) / K    host instructions per element
  elem/cycle   K / cycles
--mx gives the MX instruction count per region id (default 0).
--json-out writes the same numbers (net, overhead subtracted) for analysis/bw_model.py;
--meta adds key=value pairs to it (e.g. format=mxfp4,dwait=0).
"""
import argparse
import json
import re

ap = argparse.ArgumentParser()
ap.add_argument('log')
ap.add_argument('--k', type=int, required=True)
ap.add_argument('--mx', default='', help='id:count,... MX instructions per region')
ap.add_argument('--names', default='', help='id:name,... region labels')
ap.add_argument('--json-out', help='write the net numbers per region to this JSON file')
ap.add_argument('--meta', default='', help='key=value,... added to the JSON (e.g. format=mxfp4,dwait=0)')
args = ap.parse_args()

marks, words = {}, []
for line in open(args.log):
    m = re.match(r'\[MARK (\d+)\] cyc=(\d+)', line)
    if m:
        marks[int(m[1])] = int(m[2])
    m = re.match(r'\[SW\] 0x([0-9a-f]{8})', line)
    if m:
        words.append(int(m[1], 16))

regions = {}
for i, w in enumerate(words):
    if w >> 8 == 0xC0DE00 and (w & 0xFF) not in (0xA0, 0xE0) and i + 2 < len(words):
        regions[w & 0xFF] = (words[i + 1], words[i + 2])

mx = {int(a): int(b) for a, b in (x.split(':') for x in args.mx.split(',') if x)}
names = {int(a): b for a, b in (x.split(':', 1) for x in args.names.split(',') if x)}
cal_cyc = marks[91] - marks[90]
cal_mcyc, cal_inst = regions[90]
print(f'overhead (region 90, subtracted): MARK {cal_cyc}, mcycle {cal_mcyc}, minstret {cal_inst}')
print(f'{"region":<26}{"cycles":>8}{"mcycle":>8}{"diff":>6}{"instret":>9}{"MX":>5}'
      f'{"host/MX":>9}{"host/elem":>10}{"elem/cyc":>9}')
out = dict(k=args.k, overhead=dict(mark=cal_cyc, mcycle=cal_mcyc, minstret=cal_inst), regions={})
out.update(dict(x.split('=', 1) for x in args.meta.split(',') if x))
for rid in sorted(regions):
    if rid == 90:
        continue
    cyc = marks[rid + 1] - marks[rid] - cal_cyc
    mc = regions[rid][0] - cal_mcyc
    ins = regions[rid][1] - cal_inst
    n = mx.get(rid, 0)
    out['regions'][rid] = dict(name=names.get(rid, str(rid)), cycles=cyc, mcycle=mc, minstret=ins, mx=n)
    hmx = f'{(ins - n) / n:9.2f}' if n else f'{"-":>9}'
    print(f'{names.get(rid, str(rid)):<26}{cyc:>8}{mc:>8}{mc - cyc:>6}{ins:>9}{n:>5}{hmx}'
          f'{(ins - n) / args.k:>10.3f}{args.k / cyc:>9.3f}')
if args.json_out:
    with open(args.json_out, 'w') as f:
        json.dump(out, f, indent=2)
