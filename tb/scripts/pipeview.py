"""Cycle-by-cycle pipeline view of a make-loop VCD (program-image build).

usage (from tb/):
  make loop PROG=mxfp4 LOOP_TRACE=1 LOOP_ARGS="+stop_at=4300 +xifmon"
  python3 scripts/pipeview.py build/loop/tb_mxdotp_core.vcd build/sw/mxfp4.dis 4185 4225

Shows, per cycle (the testbench's mon_cycle_q / [XIFMON] numbering, values
just before the rising edge): which instruction each stage register holds
(IF = fetch PC, ID/EX/WB = the PC in if_id_pipe / id_ex_pipe / ex_wb_pipe,
'-' if that stage is empty), the stage ready signals, and the XIF handshakes.
Instructions are labelled from the objdump disassembly (address: mnemonic).
"""
import os
import re
import subprocess
import sys

vcd, dis, lo, hi = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
here = os.path.dirname(os.path.abspath(__file__))

asm = {}
for line in open(dis):
    m = re.match(r'\s*([0-9a-f]+):\s+[0-9a-f]+\s+(.*)', line)
    if m:
        txt = m[2].split('#')[0].strip()
        if txt.startswith('.insn'):
            txt = 'MXFUSED/MX'
        asm[int(m[1], 16)] = re.sub(r'\s+', ' ', txt)[:22]

T = 'tb_mxdotp_core.'
C = T + 'dut.core_i.'
sigs = [T + 'dbg_pc_if', T + 'dbg_pc_id', T + 'dbg_v_id', T + 'dbg_pc_ex', T + 'dbg_v_ex',
        T + 'dbg_pc_wb', T + 'dbg_v_wb', C + 'id_stage_i.id_ready_o', C + 'ex_stage_i.ex_ready_o',
        C + 'wb_stage_i.wb_ready_o', T + 'xif_issue_valid', T + 'xif_issue_ready',
        T + 'xif_commit_valid', T + 'xif_result_valid', T + 'xif_result_ready']
out = subprocess.run([sys.executable, os.path.join(here, 'vcdpeek.py'), vcd, lo, hi] + sigs,
                     capture_output=True, text=True, check=True).stdout.splitlines()


def lab(pc, v=None):
    if v == '0':
        return '-'
    try:
        a = int(pc, 16)
    except ValueError:
        return pc
    return f'{a:x} {asm.get(a, "?")}'


print(f'{"cyc":<5} {"IF":<30} {"ID":<30} {"EX":<30} {"WB":<30} rdy(ID/EX/WB) XIF')
for row in out[1:]:
    f = row.split()
    cyc, pif, pid, vid, pex, vex, pwb, vwb, rid, rex, rwb, iv, ir, cv, rv, rr = f
    xif = ''.join(['I' if iv == ir == '1' else '', 'C' if cv == '1' else '', 'R' if rv == rr == '1' else ''])
    print(f'{cyc:<5} {lab(pif):<30} {lab(pid, vid):<30} {lab(pex, vex):<30} {lab(pwb, vwb):<30} '
          f'{rid}/{rex}/{rwb}          {xif}')
