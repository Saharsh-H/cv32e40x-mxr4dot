"""Where do extra cycles go when the data port gets slower? (task 5 regime A)

Compares two traces of the same program (make loop PROG=<p> LOOP_TRACE=1, e.g. read
latency 0 and 1) instruction by instruction over one MARK region:

  python3 scripts/stall_attrib.py <base.vcd> <slow.vcd> <prog.dis> --region 20
        [--loop-func mxfp4_dot_nacc4] [--iters 20:23]

Both runs retire the same instruction stream (in-order core), so the i-th retirement
of the region is the same dynamic instruction in both. Retirement = WB holds a valid
instruction and wb_ready = 1 (testbench taps dbg_pc_wb / dbg_v_wb). For instruction i:
  delta_i = (retire_i - retire_{i-1}) in the slow run minus the same in the base run,
i.e. the extra cycles that accrue while instruction i is next to retire. They are split
by what WB was doing in those cycles (slow minus base):
  wb_data   WB holds a load/store waiting for its data response (wb_stage data_stall_o)
  wb_xif    WB holds an offloaded instruction waiting for its XIF result (xif_waiting)
  bubble    WB empty (the instruction had not arrived: an upstream stall)
  other     WB valid and not retiring for another reason, or the retire cycle itself
and the ID-stage load-use stall cycles (ctrl_byp.load_stall) in the same interval are
counted too (a load-use stall shows up later as WB bubbles).
The region is bounded by the MARK <region> and MARK <region>+1 stores (found on the data
port), each included. Output: per-PC totals (loop body per iteration of --loop-func, and
every PC outside the loop body individually), and an instruction-by-instruction listing
for the iterations given by --iters (index of the loop's first instruction, 0-based).
"""
import argparse
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

TB = 'tb_mxdotp_core'
CORE = f'{TB}.dut.core_i'
SIGS = [f'{TB}.dbg_pc_wb', f'{TB}.dbg_v_wb', f'{CORE}.wb_stage_i.wb_ready_o',
        f'{CORE}.wb_stage_i.data_stall_o', f'{CORE}.wb_stage_i.xif_waiting', f'{CORE}.ctrl_byp',
        f'{TB}.dbg_pc_ex', f'{TB}.data_req', f'{TB}.data_gnt', f'{TB}.data_we',
        f'{TB}.data_addr', f'{TB}.data_wdata']
LOAD_STALL_BIT = 6          # ctrl_byp_t (include/cv32e40x_pkg.sv), LSB = xif_lsu_stall
MMIO_MARK = 0x20000008
CATS = ('wb_data', 'wb_xif', 'bubble', 'other')


def num(v):
    return int(v, 16) if v.startswith('0x') else (int(v) if v.isdigit() else None)


def read_trace(vcd, hi):
    vcdpeek = Path(__file__).with_name('vcdpeek.py')
    txt = subprocess.run([sys.executable, str(vcdpeek), vcd, '0', str(hi)] + SIGS,
                         capture_output=True, text=True, check=True).stdout.splitlines()
    names = txt[0].split()
    rows = []
    for line in txt[1:]:
        p = line.split()
        rows.append(dict(zip(names, p)))
    return rows


def analyse(rows, region):
    retire, marks = [], {}
    for r in rows:
        c = int(r['cyc'])
        if (r['data_req'] == '1' and r['data_gnt'] == '1' and r['data_we'] == '1'
                and num(r['data_addr']) == MMIO_MARK and num(r['data_wdata']) in (region, region + 1)):
            marks[num(r['data_wdata'])] = (c, num(r['dbg_pc_ex']))
        if r['dbg_v_wb'] == '1' and r['wb_ready_o'] == '1':
            retire.append((c, num(r['dbg_pc_wb'])))
    idx = []
    for m in (region, region + 1):
        c, pc = marks[m]
        idx.append(next(i for i, (rc, rp) in enumerate(retire) if rc >= c and rp == pc))
    lo, hi = idx
    bycyc = {int(r['cyc']): r for r in rows}
    out = []
    for i in range(lo + 1, hi + 1):
        c0, c1 = retire[i - 1][0], retire[i][0]
        cnt = dict.fromkeys(CATS + ('load_stall',), 0)
        for c in range(c0 + 1, c1 + 1):
            r = bycyc[c]
            if r['dbg_v_wb'] != '1':
                cnt['bubble'] += 1
            elif r['data_stall_o'] == '1':
                cnt['wb_data'] += 1
            elif r['xif_waiting'] == '1':
                cnt['wb_xif'] += 1
            else:
                cnt['other'] += 1
            v = num(r['ctrl_byp'])
            if v is not None and (v >> LOAD_STALL_BIT) & 1:
                cnt['load_stall'] += 1
        out.append((retire[i][1], c1 - c0, cnt))
    return out, retire[lo][0], retire[hi][0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('base')
    ap.add_argument('slow')
    ap.add_argument('dis')
    ap.add_argument('--region', type=int, default=20)
    ap.add_argument('--loop-func', default='')
    ap.add_argument('--iters', default='')
    ap.add_argument('--max-cycle', type=int, default=10 ** 7)
    a = ap.parse_args()

    dis = {}
    for line in open(a.dis):
        m = re.match(r'\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+(.*)', line)
        if m:
            dis[int(m[1], 16)] = re.sub(r'\s+', ' ', m[2].split('#')[0]).strip()
    loop_lo = loop_hi = None
    if a.loop_func:   # loop body = [target of the function's backward bne, that bne]
        text = open(a.dis).read()
        body = text[text.index(f'<{a.loop_func}>:'):]
        body = body[:body.index('\n\n')] if '\n\n' in body else body
        for line in body.splitlines():
            m = re.match(r'\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+bne\s+\S+,\S+,([0-9a-f]+)', line)
            if m and int(m[2], 16) < int(m[1], 16):
                loop_lo, loop_hi = int(m[2], 16), int(m[1], 16)

    base, b0, b1 = analyse(read_trace(a.base, a.max_cycle), a.region)
    slow, s0, s1 = analyse(read_trace(a.slow, a.max_cycle), a.region)
    if [p for p, _, _ in base] != [p for p, _, _ in slow]:
        sys.exit('instruction streams differ between the two runs')
    print(f'region {a.region}: base retire {b0}..{b1} ({b1 - b0} cycles), '
          f'slow {s0}..{s1} ({s1 - s0} cycles), extra {(s1 - s0) - (b1 - b0)}, '
          f'{len(base)} instructions')

    rows = []
    for (pc, gb, cb), (_, gs, cs) in zip(base, slow):
        rows.append((pc, gs - gb, {k: cs[k] - cb[k] for k in cb}))
    in_loop = (lambda pc: loop_lo is not None and loop_lo <= pc <= loop_hi)
    iters = sum(1 for pc, _, _ in rows if pc == loop_lo)

    tot = defaultdict(lambda: [0, 0, dict.fromkeys(CATS + ('load_stall',), 0)])
    for pc, d, c in rows:
        t = tot[pc]
        t[0] += 1
        t[1] += d
        for k in c:
            t[2][k] += c[k]
    hdr = f'{"pc":>6}  {"instruction":34}{"count":>6}{"extra":>7}' + ''.join(f'{k:>11}' for k in CATS + ('load_stall',))

    def line(pc, t, div=1):
        f = (lambda x: f'{x / div:11.2f}') if div != 1 else (lambda x: f'{x:11d}')
        return (f'{pc:6x}  {dis.get(pc, "?")[:34]:34}{t[0] // div if div != 1 else t[0]:>6}'
                + (f'{t[1] / div:7.2f}' if div != 1 else f'{t[1]:7d}')
                + ''.join(f(t[2][k]) for k in CATS + ('load_stall',)))

    if loop_lo is not None:
        body = sorted(pc for pc in tot if in_loop(pc))
        print(f'\nloop body {loop_lo:#x}..{loop_hi:#x} ({a.loop_func}), {iters} iterations; per iteration:')
        print(hdr)
        for pc in body:
            print(line(pc, tot[pc], iters))
        s = sum(tot[pc][1] for pc in body)
        print(f'loop body total extra: {s} = {s / iters:.3f} per iteration')
    print('\noutside the loop body (whole region, every PC with nonzero extra or a memory access):')
    print(hdr)
    s = 0
    for pc in sorted(tot):
        if in_loop(pc):
            continue
        s += tot[pc][1]
        ins = dis.get(pc, '')
        if tot[pc][1] or re.match(r'(lw|lh|lhu|lb|lbu|sw|sh|sb)\b', ins):
            print(line(pc, tot[pc]))
    print(f'outside total extra: {s}')

    if a.iters and loop_lo is not None:
        i0, i1 = (int(x) for x in a.iters.split(':'))
        print(f'\ninstruction by instruction, iterations {i0}..{i1 - 1}:')
        print(f'{"iter":>4} {"pc":>6}  {"instruction":34}{"extra":>6}' + ''.join(f'{k:>11}' for k in CATS + ('load_stall',)))
        it = -1
        for pc, d, c in rows:
            if pc == loop_lo:
                it += 1
            if i0 <= it < i1 and in_loop(pc):
                print(f'{it:4d} {pc:6x}  {dis.get(pc, "?")[:34]:34}{d:6d}' + ''.join(f'{c[k]:11d}' for k in CATS + ('load_stall',)))


if __name__ == '__main__':
    main()
