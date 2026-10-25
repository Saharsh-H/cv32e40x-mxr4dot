#!/usr/bin/env python3
"""
pair_replay_cases.py - deliberately broken inputs for the pair replay check,
and the checks of what each one must produce. Used by tb/scripts/pair_replay.sh.

    make-a  <stim> <out_stim> <expect.json>   flip bit 0 of one expected final_result_data_o
                                              on a valid cycle -> exactly 1 mismatch there
    make-b  <stim> <out_stim> <expect.json>   flip one dotp_rs3_i (residue) bit on one mxresdot
                                              start; the bit is chosen so the golden models say
                                              that pair's final result changes -> mismatches on
                                              final_result_data_o only, equal to the golden
                                              flipped result: valid-cycle ones exactly on that
                                              pair's result cycles, invalid-cycle ones exactly on
                                              the following cycles where the captured output
                                              still holds that result (output register held)
    make-c  <stim> <out_stim>                 every input delayed by one cycle -> FAIL
    check   <expect.json> <mismatch file>     compare a replay's mismatch list with make-a/-b

Pairing for case b: the n-th mxresdot start, the n-th mailbox pop (final engine start = final_start_i
&& final_ready_o) and the n-th final result handshake (final_result_valid_o && final_result_ready_i)
belong to one pair (the mailbox is a FIFO, both engines are in order). Checked: the golden result of
the unmodified operands must equal the captured result before anything is flipped.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "verification"))
import mxdotp_golden as md   # noqa: E402
import mxfinal_golden as mf  # noqa: E402

# field index in a data line: 0 cycle, 1..13 inputs, 14..21 outputs (vcd2stim.py order)
I = dict(rst=1, d_start=2, d_id=3, d_rs1=4, d_rs2=5, d_rs3=6, d_rr=7, f_start=8, f_id=9, f_rd=10,
         f_rs1=11, f_rs2=12, f_rr=13, d_ready=14, d_valid=15, d_res_id=16, f_ready=17, f_valid=18,
         f_res_id=19, f_res_rd=20, f_data=21)


def load(path):
    head, rows = [], []
    for line in open(path):
        (head if line.startswith("#") else rows).append(line.split() if not line.startswith("#") else line)
    return head, rows


def save(path, head, rows):
    with open(path, "w") as o:
        o.writelines(head)
        o.write("\n".join(" ".join(r) for r in rows) + "\n")


def h(r, k):
    return int(r[I[k]], 16)


def setf(r, k, v):
    r[I[k]] = format(v, "0%dx" % len(r[I[k]]))


def nibs(x):
    return [(x >> (4 * i)) & 0xF for i in range(16)]


def golden(rs1, rs2, rs3, frs1, frs2):
    p1, p2, _ = md.dotp_engine_model(nibs(rs1), nibs(rs2), nibs(rs3))
    sa, sar, sw = (frs1 >> 24) & 0xFF, (frs1 >> 16) & 0xFF, (frs1 >> 8) & 0xFF
    return mf.mxfinal_frame(p1, p2, sa, sar, sw, frs2 & 0xFFFFFFFF)


def events(rows):
    ds = [i for i, r in enumerate(rows) if h(r, "rst") and h(r, "d_start")]
    fs = [i for i, r in enumerate(rows) if h(r, "rst") and h(r, "f_start") and h(r, "f_ready")]
    fr = [i for i, r in enumerate(rows) if h(r, "rst") and h(r, "f_valid") and h(r, "f_rr")]
    if not (len(ds) == len(fs) == len(fr)):
        sys.exit(f"pair_replay_cases: {len(ds)} mxresdot starts, {len(fs)} final starts, {len(fr)} results")
    return ds, fs, fr


def make_a(stim, out, expect):
    head, rows = load(stim)
    valid = [i for i, r in enumerate(rows) if h(r, "f_valid")]
    c = valid[len(valid) // 2]
    v = h(rows[c], "f_data")
    setf(rows[c], "f_data", v ^ 1)
    save(out, head, rows)
    json.dump(dict(case="a", cycles=[c], port="final_result_data_o", cls="valid", got=[format(v, "08x")]),
              open(expect, "w"))
    print(f"case a: cycle {c}, expected final_result_data_o {v:08x} -> {v ^ 1:08x} in the file")


def make_b(stim, out, expect):
    head, rows = load(stim)
    ds, fs, fr = events(rows)
    n = len(ds) // 2
    d, s, r = rows[ds[n]], rows[fs[n]], rows[fr[n]]
    rs1, rs2, rs3, frs1, frs2 = h(d, "d_rs1"), h(d, "d_rs2"), h(d, "d_rs3"), h(s, "f_rs1"), h(s, "f_rs2")
    orig = golden(rs1, rs2, rs3, frs1, frs2)
    if orig != h(r, "f_data"):
        sys.exit(f"pair_replay_cases: pair {n}: golden {orig:08x} != captured {h(r, 'f_data'):08x} (pairing wrong)")
    for bit in range(64):
        new = golden(rs1, rs2, rs3 ^ (1 << bit), frs1, frs2)
        if new != orig:
            break
    else:
        sys.exit(f"pair_replay_cases: no rs3 bit changes pair {n}'s result")
    setf(d, "d_rs3", rs3 ^ (1 << bit))
    prev = fr[n - 1] if n else -1
    window = [i for i in range(prev + 1, fr[n] + 1) if h(rows[i], "f_valid")]
    # After the handshake the engine's output register keeps showing this result (valid low)
    # until the next result replaces it, so the flipped value also appears there: those
    # cycles are predicted as invalid-cycle mismatches, read from the capture itself.
    hold = []
    i = fr[n] + 1
    while i < len(rows) and not h(rows[i], "f_valid") and h(rows[i], "f_data") == orig:
        hold.append(i)
        i += 1
    save(out, head, rows)
    json.dump(dict(case="b", cycles=window + hold, port="final_result_data_o",
                   cls=["valid"] * len(window) + ["invalid"] * len(hold),
                   got=[format(new, "08x")] * (len(window) + len(hold)), pair=n, bit=bit,
                   start_cycle=ds[n], orig=format(orig, "08x"), new=format(new, "08x")), open(expect, "w"))
    print(f"case b: pair {n} (mxresdot start cycle {ds[n]}, final start {fs[n]}, result cycle {fr[n]}): "
          f"rs3 bit {bit} flipped; golden result {orig:08x} (= captured) -> {new:08x}; "
          f"predicted: valid-cycle mismatches at {window}, invalid-cycle (held output) at {hold}")


def make_c(stim, out):
    head, rows = load(stim)
    shifted = [r[:] for r in rows]
    for i in range(1, len(rows)):
        shifted[i][1:14] = rows[i - 1][1:14]
    save(out, head, shifted)
    print("case c: inputs delayed by one cycle")


def check(expect, mm):
    e = json.load(open(expect))
    got = [l.split() for l in open(mm) if l.strip()]
    cls = e["cls"] if isinstance(e["cls"], list) else [e["cls"]] * len(e["cycles"])
    want = [[str(c), e["port"], k] for c, k in zip(e["cycles"], cls)]
    ok = [g[:3] for g in got] == want and [g[4] for g in got] == e["got"]
    print(f"case {e['case']}: {len(got)} mismatch(es) {'as predicted' if ok else 'NOT as predicted'}: "
          + "; ".join(" ".join(g) for g in got[:6]))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {"make-a": make_a, "make-b": make_b, "make-c": make_c, "check": check}[cmd](*args)
