"""Golden-model expected results for the directed stream test (make stream).

usage (from tb/):  python3 scripts/stream_expected.py [path/to/verification]
                   (defaults to ../../verification relative to this script)

Starts from the exact 64-bit register values the stream program loads, unpacks
them the way the RTL does (element i = rs[4i+3:4i] for FP4, byte i for FP8;
rs3 = {.., meta[56:49], e5m2[48], b_scale[47:40], a_scale[39:32], acc[31:0]};
mxfinal rs1 = {a_scale, ar_scale, b_scale, rsvd}), and for every value requires
the bit-level golden model and its exact-Fraction reference to agree.
"""
import os
import sys
VERIF_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', '..', 'verification')
sys.path.insert(0, VERIF_DIR)
import fp4_golden as f4
import fp8_golden as f8
import m2_golden as m2
import mxdotp_golden as md
import mxfinal_golden as mf

# --- register values the stream program loads (must match instr_rom.sv) ---
A4      = 0x2222_2222_2222_2222   # x2/x3   MXFP4 16x 1.0
B4      = 0x2222_2222_2222_2222   # x4/x5   MXFP4 16x 1.0
RS3_4   = 0x0000_7F7F_0000_0000   # x6/x7   {b=127, a=127}, acc = 0.0
AB8     = 0x3838_3838_3838_3838   # x8/x9   E4M3 8x 1.0 (A = B)
RS3_8   = 0x0000_7F7F_0000_0000   # x10/x11 bit48 = 0 -> E4M3, acc = 0.0
A_M2    = 0x2222_2222_2222_2722   # x12/x13 Test 4's U activations
RS3_M2  = 0x013E_7F7F_0000_0000   # x14/x15 sg_em={2,1}, elem_em={3,3}, acc = 0.0
AR4     = 0x1111_1111_1111_1111   # x16/x17 residue 16x 0.5
RSCALES = 0x7F7F_7F00             # x18     {a=127, ar=127, b=127, rsvd}
RACC    = 0x0000_0000             # x19     mxfinal old acc = 0.0
CHAIN_ACC0 = 0x0000_0000          # x28     chain accumulator start

def nibs(v):  return [(v >> (4 * i)) & 0xF for i in range(16)]
def bytes8(v): return [(v >> (8 * i)) & 0xFF for i in range(8)]
def rs3_fields(r):
    return dict(acc=r & 0xFFFFFFFF, a=(r >> 32) & 0xFF, b=(r >> 40) & 0xFF,
                e5m2=(r >> 48) & 1, meta=(r >> 49) & 0xFF)

def fp4(a, b, rs3, acc=None):
    f = rs3_fields(rs3); acc = f['acc'] if acc is None else acc
    got = f4.fp4_fused_model(nibs(a), nibs(b), f['a'], f['b'], acc)
    ref = f4.project_rne(f4.reference(nibs(a), nibs(b), f['a'], f['b'], acc))
    assert got == ref, (hex(got), hex(ref))
    return got

def fp8(a, b, rs3):
    f = rs3_fields(rs3)
    got = f8.fp8_fused_model(bytes8(a), bytes8(b), f['a'], f['b'], f['acc'], f['e5m2'])
    ref = f8.project_rne(f8.reference(bytes8(a), bytes8(b), f['a'], f['b'], f['acc'], f['e5m2']))
    assert got == ref, (hex(got), hex(ref))
    return got

def m2x(a, b, rs3):
    f = rs3_fields(rs3)
    e = [f['meta'] & 3, (f['meta'] >> 2) & 3]          # elem_em[sg0], [sg1]
    s = [(f['meta'] >> 4) & 3, (f['meta'] >> 6) & 3]   # sg_em[sg0],  [sg1]
    got = m2.m2_fused_model(nibs(a), nibs(b), e, s, f['a'], f['b'], f['acc'])
    ref = m2.project_rne(m2.reference(nibs(a), nibs(b), e, s, f['a'], f['b'], f['acc']))
    assert got == ref, (hex(got), hex(ref))
    return got, e, s

def residue(a, b, ar, rs1, acc):
    sa, sar, sw = (rs1 >> 24) & 0xFF, (rs1 >> 16) & 0xFF, (rs1 >> 8) & 0xFF
    p1, p2, _ = md.dotp_engine_model(nibs(a), nibs(b), nibs(ar))
    ed = md.exact_end_to_end(nibs(a), nibs(b), nibs(ar), sa, sar, sw, acc)
    ev = mf.exact_value(p1, p2, sa, sar, sw, acc)
    assert ed == ev
    got = mf.mxfinal_frame(p1, p2, sa, sar, sw, acc)
    assert got == mf.mxfinal_ref(p1, p2, sa, sar, sw, acc), "frame vs ref"
    return got, p1, p2

def f(bits): return float(mf.fp32_bits_to_fraction(bits))

s1 = fp4(A4, B4, RS3_4)
s2 = fp8(AB8, AB8, RS3_8)
s3, e, s = m2x(A_M2, B4, RS3_M2)
s4, p1, p2 = residue(A4, B4, AR4, RSCALES, RACC)
print(f"S1 MXFP4      0x{s1:08X}  {f(s1)}")
print(f"S2 MXFP8 E4M3 0x{s2:08X}  {f(s2)}")
print(f"S3 M2XFP4     0x{s3:08X}  {f(s3)}   (elem_em={e}, sg_em={s})")
print(f"S4 mxfinal    0x{s4:08X}  {f(s4)}   (mxresdot p1={p1}, p2={p2})")
acc = CHAIN_ACC0
chain = []
for k in range(16):
    acc = fp4(A4, B4, RS3_4 & ~0xFFFFFFFF, acc=acc)
    chain.append(acc)
print("S5 chain     " + " ".join(f"{f(x):g}" for x in chain))
print("S5 chain hex " + " ".join(f"{x:08X}" for x in chain))
