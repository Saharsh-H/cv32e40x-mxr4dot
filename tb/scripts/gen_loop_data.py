"""Operand data + golden expected results for the K-element dot-product loops
(make loop PROG=<fmt>), task 3.

usage (from tb/):
  python3 scripts/gen_loop_data.py --format mxfp4 --k 4096 --seed 1 \\
      --out-s build/sw/mxfp4_data.S --out-json build/sw/mxfp4_expected.json
  formats: mxfp4, mxfp8 (E4M3), mxfp4r (residue on activations)

Design
------
1. Real-valued operands, fixed seed (Python's `random`, deterministic per seed):
     activations a_i ~ N(0, 1) * 2^u_b, with 1 % of elements (positions drawn
                 from the seed) multiplied by 8 for outliers;
     weights     w_i ~ N(0, 1) * 0.02 * 2^v_b;
   where u_b ~ U{-12..12} and v_b ~ U{-6..6} are drawn per 32-element block.
   The per-block magnitude spread is deliberate: without it (first try,
   21 Oct) every partial sum fits FP32's 24-bit mantissa exactly, no step ever
   rounds, and the bit-exact checks could not tell a wrong rounding or
   accumulation order from a right one. The generator therefore counts the
   inexact steps (RNE(acc + SoP) != acc + SoP) of every chain and refuses data
   where fewer than MIN_INEXACT_FRAC of the steps round. This is a synthetic
   coverage set for the correctness checks, not an accuracy study; engine
   timing does not depend on the values.
2. OCP MX quantisation per block of k = 32 (OCP MX v1.0): shared exponent
   S = floor(log2(amax)) - emax_elem, E8M0 byte = S + 127; each element x / 2^S
   rounded to the nearest representable value, ties to even code, saturating
   at the largest finite magnitude. An all-zero block gets E8M0 127.
     mxfp4 : E2M1, emax 2, saturate at 6.
     mxfp8 : E4M3, emax 8, saturate at 448 (the NaN codes 0x7F/0xFF are never
             produced).
     mxfp4r: activations = MXFP4 primary + MXFP4 residue of the primary's
             error (same rule on e = a - dequant(primary), own scale S_ar);
             weights plain MXFP4. An all-zero residue block gets S_ar = S_a, so
             Property 1 (S_ar <= S_a) always holds - asserted.
3. Memory layout, exactly as the kernels read it (all little-endian):
     FP4 arrays (mx_a, mx_w, mx_ar): K/2 bytes; byte j = element 2j (low
       nibble) | element 2j+1 (high nibble); instruction n's 64-bit operand
       (16 elements, element i at bits [4i+3:4i]) = the word pair at byte 8n.
     FP8 arrays (mx_a, mx_w): K bytes; instruction n's operand (8 elements,
       element i at bits [8i+7:8i]) = the word pair at byte 8n.
     scales (mx_sa, mx_sw, mx_sar): K/32 E8M0 bytes, one per block.
4. Golden expected values, bit-exact, computed in the kernels' exact order,
   one "step" per group (mxfp4: one mxfused, 16 elements; mxfp8: one mxfused,
   8 elements; mxfp4r: one mxresdot + mxfinal pair, 16 elements):
     mxfp4  : fp4_golden.fp4_fused_model, each step also == project_rne(reference)
     mxfp8  : fp8_golden.fp8_fused_model (E4M3), each step also == project_rne(reference)
     mxfp4r : mxdotp_golden.dotp_engine_model -> (p1, p2), then
              mxfinal_golden.mxfinal_frame, each step also == mxfinal_ref, and
              mxdotp_golden.exact_end_to_end == mxfinal_golden.exact_value
   NACC=1: one accumulator, groups n = 0, 1, ...; NACC=4: accumulator j takes
   groups n = j, j+4, ...; combined as (a0 + a1) + (a2 + a3) with soft-float
   (IEEE RNE), modelled as exact sum + RNE (= IEEE for the normal-range values
   asserted here). The software baselines (mxfp4, mxfp8) perform the same
   per-group RNE(acc + exact group sum), so their expected value is NACC=1.
   Every accumulator value is asserted to be zero or FP32 normal.
5. Outputs: an assembly data file (.S: the arrays + expected words exp_nacc1,
   exp_nacc4[4], exp_nacc4_sum), a JSON summary, and a printed table.
"""
import argparse
import json
import math
import os
import random
import sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'verification'))
import fp4_golden as f4      # noqa: E402
import fp8_golden as f8      # noqa: E402
import mxdotp_golden as md   # noqa: E402
import mxfinal_golden as mf  # noqa: E402

BLOCK = 32          # OCP MX block size
U_SPAN = 12         # activation per-block magnitude spread 2^U{-U_SPAN..U_SPAN}
V_SPAN = 6          # weight per-block magnitude spread
MIN_INEXACT_FRAC = 0.25

E2M1_EMAX = 2
E2M1_MAGS = [Fraction(0), Fraction(1, 2), Fraction(1), Fraction(3, 2),
             Fraction(2), Fraction(3), Fraction(4), Fraction(6)]   # code 0..7
E4M3_EMAX = 8
E4M3_MAX = Fraction(448)
E4M3_NAN = (0x7F, 0xFF)


# ---------------------------------------------------------------------------
# values and quantisation
# ---------------------------------------------------------------------------
def gen_values(k, seed):
    rng = random.Random(seed)
    nb = k // BLOCK
    u = [rng.randint(-U_SPAN, U_SPAN) for _ in range(nb)]
    v = [rng.randint(-V_SPAN, V_SPAN) for _ in range(nb)]
    a = [rng.gauss(0.0, 1.0) * 2.0 ** u[i // BLOCK] for i in range(k)]
    for i in rng.sample(range(k), k // 100):
        a[i] *= 8.0
    w = [rng.gauss(0.0, 1.0) * 0.02 * 2.0 ** v[i // BLOCK] for i in range(k)]
    return a, w


def shared_exp(blk, emax):
    """OCP shared exponent of a block of Fractions (None for an all-zero block)."""
    amax = max(abs(v) for v in blk)
    if amax == 0:
        return None
    s = math.floor(math.log2(amax)) - emax
    while Fraction(2) ** (s + emax) > amax:      # guard float log2 at powers of two
        s -= 1
    while Fraction(2) ** (s + emax + 1) <= amax:
        s += 1
    return s


def nearest_code(x, table, max_code_pos):
    """table: list of (code, value) for non-negative values, sorted by value.
    Nearest value, ties to even code; saturate at the largest. Returns code
    without sign."""
    m = -x if x < 0 else x
    if m >= table[-1][1]:
        return max_code_pos
    for (c0, v0), (c1, v1) in zip(table, table[1:]):
        if v0 <= m < v1:
            d0, d1 = m - v0, v1 - m
            return c0 if d0 < d1 else c1 if d1 < d0 else (c0 if c0 % 2 == 0 else c1)
    raise AssertionError(x)


E2M1_TABLE = [(c, E2M1_MAGS[c]) for c in range(8)]
E4M3_TABLE = sorted(((c, f8.fp8_value(c, 0)) for c in range(0x7F)), key=lambda t: t[1])
assert E4M3_TABLE[-1] == (0x7E, E4M3_MAX)


def quantize(vals, fmt, scales_override=None):
    """Block-wise OCP quantisation -> (element codes, E8M0 scale bytes).
    scales_override: per-block scale bytes to use for all-zero blocks (mxfp4r)."""
    emax, table, maxc, sbit = ((E2M1_EMAX, E2M1_TABLE, 7, 3) if fmt == 'fp4'
                               else (E4M3_EMAX, E4M3_TABLE, 0x7E, 7))
    codes, scales = [], []
    for bi, b in enumerate(range(0, len(vals), BLOCK)):
        blk = [Fraction(v) for v in vals[b:b + BLOCK]]
        s = shared_exp(blk, emax)
        if s is None:
            raw = scales_override[bi] if scales_override else 127
            s = raw - 127
        raw = s + 127
        assert 0 <= raw <= 254, raw
        scales.append(raw)
        for v in blk:
            x = v / Fraction(2) ** s
            codes.append(((1 << sbit) if x < 0 else 0) | nearest_code(x, table, maxc))
    return codes, scales


def check_quantizer(vals, codes, scales, fmt):
    """Self-checks: decode tables match the golden models; per block, amax/2^S is
    in [2^emax, 2^(emax+1)) (OCP shared scale); every element is the nearest
    representable value or saturated."""
    if fmt == 'fp4':
        for c in range(16):
            assert f4.fp4_value(c) == (-1 if c & 8 else 1) * E2M1_MAGS[c & 7], c
        emax, value, vmax = E2M1_EMAX, f4.fp4_value, Fraction(6)
        allv = [v for _, v in E2M1_TABLE]
    else:
        emax, value, vmax = E4M3_EMAX, (lambda c: f8.fp8_value(c, 0)), E4M3_MAX
        allv = [v for _, v in E4M3_TABLE]
        assert not any(c in E4M3_NAN for c in codes)
    allv = allv + [-v for v in allv]
    for bi, b in enumerate(range(0, len(vals), BLOCK)):
        blk = [Fraction(v) for v in vals[b:b + BLOCK]]
        amax = max(abs(v) for v in blk)
        sc = Fraction(2) ** (scales[bi] - 127)
        if amax:
            assert 2 ** emax <= amax / sc < 2 ** (emax + 1), (bi, float(amax / sc))
        for v, c in zip(blk, codes[b:b + BLOCK]):
            x, q = v / sc, value(c)
            if abs(x) >= vmax:
                assert q == (vmax if x > 0 else -vmax)
                continue
            assert abs(x - q) == min(abs(x - m) for m in allv), (bi, float(x), float(q))


def pack_fp4(codes):
    by = bytes(codes[2 * j] | (codes[2 * j + 1] << 4) for j in range(len(codes) // 2))
    for n in range(len(codes) // 16):   # round trip into the RTL's nibble order
        op = int.from_bytes(by[8 * n:8 * n + 8], 'little')
        assert [(op >> (4 * i)) & 0xF for i in range(16)] == codes[16 * n:16 * n + 16], n
    return by


def pack_fp8(codes):
    by = bytes(codes)
    for n in range(len(codes) // 8):    # round trip into the RTL's byte order
        op = int.from_bytes(by[8 * n:8 * n + 8], 'little')
        assert [(op >> (8 * i)) & 0xFF for i in range(8)] == codes[8 * n:8 * n + 8], n
    return by


# ---------------------------------------------------------------------------
# golden chains
# ---------------------------------------------------------------------------
def is_normal_or_zero(bits):
    e = (bits >> 23) & 0xFF
    return (bits & 0x7FFFFFFF) == 0 or 1 <= e <= 254


def f32_add(x, y):
    r = f4.project_rne(f4.fp32_decode_exact(x) + f4.fp32_decode_exact(y))
    assert is_normal_or_zero(r)
    return r


def chains(n_groups, step):
    """step(n, acc) -> (new_acc, exact). Returns NACC=1 / NACC=4 results + stats."""
    st1, st4 = dict(steps=0, inexact=0), dict(steps=0, inexact=0)

    def run(n, acc, st):
        got, exact = step(n, acc)
        assert is_normal_or_zero(got), hex(got)
        st['steps'] += 1
        st['inexact'] += f4.fp32_decode_exact(got) != exact
        return got

    acc1 = 0
    for n in range(n_groups):
        acc1 = run(n, acc1, st1)
    acc4 = [0, 0, 0, 0]
    for n in range(n_groups):
        acc4[n % 4] = run(n, acc4[n % 4], st4)
    for name, st in (('NACC=1', st1), ('NACC=4', st4)):
        assert st['inexact'] >= MIN_INEXACT_FRAC * st['steps'], \
            f'{name}: only {st["inexact"]}/{st["steps"]} steps round - data too benign for a bit-exact check'
    sum4 = f32_add(f32_add(acc4[0], acc4[1]), f32_add(acc4[2], acc4[3]))
    return dict(exp_nacc1=acc1, exp_nacc4=acc4, exp_nacc4_sum=sum4), st1, st4


def run_mxfp4(k, seed):
    a, w = gen_values(k, seed)
    an, sa = quantize(a, 'fp4')
    wn, sw = quantize(w, 'fp4')
    check_quantizer(a, an, sa, 'fp4')
    check_quantizer(w, wn, sw, 'fp4')

    def step(n, acc):
        x, y, s1, s2 = an[16 * n:16 * n + 16], wn[16 * n:16 * n + 16], sa[n // 2], sw[n // 2]
        got = f4.fp4_fused_model(x, y, s1, s2, acc)
        exact = f4.reference(x, y, s1, s2, acc)
        assert got == f4.project_rne(exact), n
        return got, exact

    exp, st1, st4 = chains(k // 16, step)
    exact = sum(f4.fp4_value(x) * f4.fp4_value(y) * Fraction(2) ** (sa[i // BLOCK] + sw[i // BLOCK] - 254)
                for i, (x, y) in enumerate(zip(an, wn)))
    arrays = [('mx_a', pack_fp4(an)), ('mx_w', pack_fp4(wn)), ('mx_sa', bytes(sa)), ('mx_sw', bytes(sw))]
    return arrays, exp, st1, st4, dict(groups=k // 16, mx_instr=k // 16, exact=exact,
                                       real=sum(x * y for x, y in zip(a, w)), scales=dict(a=sa, w=sw))


def run_mxfp8(k, seed):
    a, w = gen_values(k, seed)
    ab, sa = quantize(a, 'fp8')
    wb, sw = quantize(w, 'fp8')
    check_quantizer(a, ab, sa, 'fp8')
    check_quantizer(w, wb, sw, 'fp8')

    def step(n, acc):
        x, y, s1, s2 = ab[8 * n:8 * n + 8], wb[8 * n:8 * n + 8], sa[n // 4], sw[n // 4]
        got = f8.fp8_fused_model(x, y, s1, s2, acc, 0)
        exact = f8.reference(x, y, s1, s2, acc, 0)
        assert got == f8.project_rne(exact), n
        return got, exact

    exp, st1, st4 = chains(k // 8, step)
    exact = sum(f8.fp8_value(x, 0) * f8.fp8_value(y, 0) * Fraction(2) ** (sa[i // BLOCK] + sw[i // BLOCK] - 254)
                for i, (x, y) in enumerate(zip(ab, wb)))
    arrays = [('mx_a', pack_fp8(ab)), ('mx_w', pack_fp8(wb)), ('mx_sa', bytes(sa)), ('mx_sw', bytes(sw))]
    return arrays, exp, st1, st4, dict(groups=k // 8, mx_instr=k // 8, exact=exact,
                                       real=sum(x * y for x, y in zip(a, w)), scales=dict(a=sa, w=sw))


def run_mxfp4r(k, seed):
    a, w = gen_values(k, seed)
    an, sa = quantize(a, 'fp4')
    err = [Fraction(x) - f4.fp4_value(c) * Fraction(2) ** (sa[i // BLOCK] - 127) for i, (x, c) in enumerate(zip(a, an))]
    arn, sar = quantize(err, 'fp4', scales_override=sa)
    wn, sw = quantize(w, 'fp4')
    check_quantizer(a, an, sa, 'fp4')
    check_quantizer(err, arn, sar, 'fp4')
    check_quantizer(w, wn, sw, 'fp4')
    assert all(r <= p for r, p in zip(sar, sa)), 'Property 1 (S_ar <= S_a) violated'
    margins = [p - r for r, p in zip(sar, sa)]

    def step(n, acc):
        x, y, z = an[16 * n:16 * n + 16], wn[16 * n:16 * n + 16], arn[16 * n:16 * n + 16]
        s_a, s_ar, s_w = sa[n // 2], sar[n // 2], sw[n // 2]
        p1, p2, _ = md.dotp_engine_model(x, y, z)
        got = mf.mxfinal_frame(p1, p2, s_a, s_ar, s_w, acc)
        exact = mf.exact_value(p1, p2, s_a, s_ar, s_w, acc)
        assert exact == md.exact_end_to_end(x, y, z, s_a, s_ar, s_w, acc), n
        assert got == mf.mxfinal_ref(p1, p2, s_a, s_ar, s_w, acc), n
        return got, exact

    exp, st1, st4 = chains(k // 16, step)
    exact = sum((f4.fp4_value(x) * Fraction(2) ** (sa[i // BLOCK] - 127)
                 + f4.fp4_value(z) * Fraction(2) ** (sar[i // BLOCK] - 127))
                * f4.fp4_value(y) * Fraction(2) ** (sw[i // BLOCK] - 127)
                for i, (x, y, z) in enumerate(zip(an, wn, arn)))
    arrays = [('mx_a', pack_fp4(an)), ('mx_w', pack_fp4(wn)), ('mx_ar', pack_fp4(arn)),
              ('mx_sa', bytes(sa)), ('mx_sar', bytes(sar)), ('mx_sw', bytes(sw))]
    return arrays, exp, st1, st4, dict(groups=k // 16, mx_instr=2 * (k // 16), exact=exact,
                                       real=sum(x * y for x, y in zip(a, w)),
                                       scales=dict(a=sa, ar=sar, w=sw),
                                       property1_margin=[min(margins), max(margins)])


RUN = dict(mxfp4=run_mxfp4, mxfp8=run_mxfp8, mxfp4r=run_mxfp4r)


# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
def bits_to_float(b):
    return float(f4.fp32_decode_exact(b))


def write_s(path, args, arrays, exp):
    with open(path, 'w') as f:
        f.write(f'/* Generated by tb/scripts/gen_loop_data.py --format {args.format} --k {args.k} '
                f'--seed {args.seed}.\n * Do not edit; regenerate. */\n')
        f.write('  .section .data\n')
        for name, data in arrays:
            f.write(f'  .balign 8\n  .globl {name}\n{name}:\n')
            for i in range(0, len(data), 16):
                f.write('  .byte ' + ', '.join(f'0x{x:02x}' for x in data[i:i + 16]) + '\n')
        f.write('  .balign 4\n')
        f.write(f'  .globl exp_nacc1\nexp_nacc1: .word 0x{exp["exp_nacc1"]:08x}\n')
        f.write('  .globl exp_nacc4\nexp_nacc4: .word ' + ', '.join(f'0x{x:08x}' for x in exp['exp_nacc4']) + '\n')
        f.write(f'  .globl exp_nacc4_sum\nexp_nacc4_sum: .word 0x{exp["exp_nacc4_sum"]:08x}\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--format', required=True, choices=sorted(RUN))
    ap.add_argument('--k', type=int, default=4096)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--out-s')
    ap.add_argument('--out-json')
    args = ap.parse_args()
    assert args.k % 128 == 0, 'K must be a multiple of 128 (4 accumulators x 32-element blocks)'

    arrays, exp, st1, st4, info = RUN[args.format](args.k, args.seed)
    sc = info['scales']
    print(f'format={args.format} K={args.k} seed={args.seed} groups={info["groups"]} '
          f'MX instructions={info["mx_instr"]}')
    print('  E8M0 scale range: ' + ', '.join(f'{n.upper()} [{min(v)}, {max(v)}]' for n, v in sc.items()))
    if 'property1_margin' in info:
        print(f'  Property 1 margin S_a - S_ar: min {info["property1_margin"][0]}, max {info["property1_margin"][1]}')
    print(f'  steps that round (RNE != exact): NACC=1 {st1["inexact"]}/{st1["steps"]}, '
          f'NACC=4 {st4["inexact"]}/{st4["steps"]}')
    print(f'  NACC=1  (and software baseline): 0x{exp["exp_nacc1"]:08x}  {bits_to_float(exp["exp_nacc1"])!r}')
    for j, x in enumerate(exp['exp_nacc4']):
        print(f'  NACC=4  acc{j}: 0x{x:08x}  {bits_to_float(x)!r}')
    print(f'  NACC=4  (a0+a1)+(a2+a3): 0x{exp["exp_nacc4_sum"]:08x}  {bits_to_float(exp["exp_nacc4_sum"])!r}')
    print(f'  info: exact dot of quantised operands {float(info["exact"])!r} '
          f'(single RNE 0x{f4.project_rne(info["exact"]):08x}); unquantised real dot {info["real"]!r}')
    if args.out_s:
        write_s(args.out_s, args, arrays, exp)
    if args.out_json:
        with open(args.out_json, 'w') as f:
            json.dump(dict(format=args.format, k=args.k, seed=args.seed, expected=exp,
                           groups=info['groups'], mx_instr=info['mx_instr'],
                           inexact_steps_nacc1=[st1['inexact'], st1['steps']],
                           inexact_steps_nacc4=[st4['inexact'], st4['steps']],
                           exact_dot=float(info['exact'])), f, indent=2)


if __name__ == '__main__':
    main()
