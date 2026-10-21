"""Print selected VCD signals as seen just before each rising clock edge.

usage (from tb/):
  python3 scripts/vcdpeek.py <vcd> <cyc_from> <cyc_to> <sig_path> [<sig_path> ...]
  python3 scripts/vcdpeek.py <vcd> --grep <substring>       (list matching signal paths)
VCDs: tb/tb_mxdotp_core.vcd (make full), tb/build/stream/tb_mxdotp_core.vcd (make stream).
Note: aliased nets share one VCD id; only one of the aliases is tracked (shows 'x').

sig_path is dot-separated below TOP, e.g. tb_mxdotp_core.dut.xif.issue_valid.
Rows are labelled with the testbench's own mon_cycle_q (pre-edge value), i.e.
exactly the [XIFMON] cyc= numbering. Values are the pre-edge values (what an always_ff
samples at that edge).
"""
import sys

def parse_header(f):
    scope, sigs = [], {}
    for line in f:
        s = line.strip()
        if s.startswith('$scope'):
            scope.append(s.split()[2])
        elif s.startswith('$upscope'):
            scope.pop()
        elif s.startswith('$var'):
            p = s.split()
            path = '.'.join(scope[1:] + [p[4]])
            sigs.setdefault(path, (p[3], int(p[2])))
        elif s.startswith('$enddefinitions'):
            return sigs
    return sigs

def main():
    vcd = sys.argv[1]
    with open(vcd) as f:
        sigs = parse_header(f)
        if sys.argv[2] == '--grep':
            for k in sorted(sigs):
                if sys.argv[3] in k:
                    print(k, sigs[k][1])
            return
        lo, hi = int(sys.argv[2]), int(sys.argv[3])
        want = sys.argv[4:]
        clk = sigs['tb_mxdotp_core.clk_i'][0]
        rst = sigs['tb_mxdotp_core.rst_ni'][0]
        ids = {sigs[w][0]: w for w in want}
        cur = {w: 'x' for w in want}
        rst_v, clk_v = '0', '0'
        cyc = None
        rows = []
        mon = sigs['tb_mxdotp_core.mon_cycle_q'][0]
        mon_v = 'x'
        snap, snap_rst, snap_mon = dict(cur), rst_v, mon_v
        for line in f:
            if line[0] == '#':
                # values as they stand when this timestamp begins = pre-edge
                snap, snap_rst, snap_mon = dict(cur), rst_v, mon_v
                continue
            s = line.strip()
            if not s or s[0] == '$':
                continue
            if s[0] in 'br':
                val, ident = s[1:].split()
            else:
                val, ident = s[0], s[1:]
            if ident == clk:
                if val == '1' and clk_v == '0' and snap_rst == '1':
                    c = int(snap_mon, 2) if set(snap_mon) <= {'0', '1'} else None
                    if c is not None and lo <= c <= hi:
                        rows.append((c, dict(snap)))
                    if c is not None and c > hi:
                        break
                clk_v = val
                continue
            if ident == rst:
                rst_v = val
            if ident == mon:
                mon_v = val
            if ident in ids:
                v = val
                if len(v) > 1:
                    v = hex(int(v, 2)) if set(v) <= {'0', '1'} else v
                cur[ids[ident]] = v
        print('cyc  ' + '  '.join(w.split('.')[-1] for w in want))
        for c, vals in rows:
            print(f'{c:<4} ' + '  '.join(str(vals[w]) for w in want))

if __name__ == '__main__':
    main()
