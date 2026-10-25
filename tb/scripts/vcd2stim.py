#!/usr/bin/env python3
"""
vcd2stim.py - cut the residue pair out of a system-testbench VCD.

    python3 tb/scripts/vcd2stim.py <tb_mxdotp_core.vcd> <stim.txt> [--source NAME] [--json cov.json]

Reads the signals at the boundary between mxdotp_xif and the residue pair
(mxresdot engine + mxdotp_mailbox + mxfinal engine), as syn/wrappers/
mx_syn_pair.sv defines it, and writes one line per rising clock edge: the
value of every wrapper input and every expected wrapper output just BEFORE
that edge (the values the flops sample). tb/pair_replay/tb_pair_replay.sv
replays the file against mx_syn_pair. Run by tb/scripts/pair_replay.sh.

System signal for each wrapper port (all under tb_mxdotp_core.dut.mxdotp_i,
line numbers mxdotp_xif.sv at 6d373a46):
  inputs   rst_ni                rst_ni
           dotp_start_i          dotp_engine_i.start_i      (= dotp_engine_start, :622)
           dotp_id/rs1/rs2/rs3_i dotp_engine_i.id_i/rs1_i/rs2_i/rs3_i
           dotp_result_ready_i   dotp_result_ready_xif      (:889)
           final_start_i         final_pending_head_ok      (:367)
           final_id/rd/rs1/rs2_i final_engine_i.id_i/rd_i/rs1_i/rs2_i
           final_result_ready_i  final_result_ready         (:888)
  outputs  dotp_ready_o          dotp_engine_i.ready_o
           dotp_result_valid_o   dotp_result_valid && !mailbox_full   (:974; also :603, :633)
           dotp_result_id_o      dotp_engine_i.result_id_o
           final_ready_o         mailbox_valid_q && final_engine_ready (:653)
           final_result_valid_o / id_o / rd_o / data_o
                                 final_engine_i.result_valid_o / result_id_o / result_rd_o / result_data
The xif's order-queue head gating of the XIF result channel (:966-988, :889)
is outside the pair: it reaches the pair only through the captured
*_result_ready_i inputs, and neither this check nor the wrapper's synthesis
covers it.

Cross-checks on every sampled edge (any failure stops with exit 2), so the
boundary reading above is tested against the waveform itself:
  dotp_engine_i.result_ready_i  == !mailbox_full && dotp_result_ready_xif   (:633)
  final_engine_i.start_i        == final_pending_head_ok && final_ready     (:653)
  final_engine_i.result_ready_i == final_result_ready
Coverage counts (printed, and written with --json) say what each source can
and cannot exercise.
"""
import argparse
import json
import sys

P = "TOP.tb_mxdotp_core.dut.mxdotp_i."
D = P + "dotp_engine_i."
F = P + "final_engine_i."

# key -> (full VCD path, width)
SIGNALS = {
    "clk": (P + "clk_i", 1),
    "rst_ni": (P + "rst_ni", 1),
    "d_start": (D + "start_i", 1),
    "d_id": (D + "id_i", 4),
    "d_rs1": (D + "rs1_i", 64),
    "d_rs2": (D + "rs2_i", 64),
    "d_rs3": (D + "rs3_i", 64),
    "d_rr_xif": (P + "dotp_result_ready_xif", 1),
    "f_head_ok": (P + "final_pending_head_ok", 1),
    "f_id": (F + "id_i", 4),
    "f_rd": (F + "rd_i", 5),
    "f_rs1": (F + "rs1_i", 64),
    "f_rs2": (F + "rs2_i", 64),
    "f_rr": (P + "final_result_ready", 1),
    "d_ready": (D + "ready_o", 1),
    "d_valid_raw": (P + "dotp_result_valid", 1),
    "mb_full": (P + "mailbox_full", 1),
    "d_res_id": (D + "result_id_o", 4),
    "mb_valid": (P + "mailbox_valid_q", 1),
    "f_eng_ready": (P + "final_engine_ready", 1),
    "f_valid": (F + "result_valid_o", 1),
    "f_res_id": (F + "result_id_o", 4),
    "f_res_rd": (F + "result_rd_o", 5),
    "f_res_data": (F + "result_data", 32),
    # cross-check only
    "x_d_eng_rr": (D + "result_ready_i", 1),
    "x_f_eng_start": (F + "start_i", 1),
    "x_f_eng_rr": (F + "result_ready_i", 1),
}

# Line layout: cycle, 13 inputs, 8 outputs (hex, fixed widths). Must match tb_pair_replay.sv.
IN_FIELDS = [("rst_ni", 1), ("dotp_start_i", 1), ("dotp_id_i", 4), ("dotp_rs1_i", 64),
             ("dotp_rs2_i", 64), ("dotp_rs3_i", 64), ("dotp_result_ready_i", 1),
             ("final_start_i", 1), ("final_id_i", 4), ("final_rd_i", 5),
             ("final_rs1_i", 64), ("final_rs2_i", 64), ("final_result_ready_i", 1)]
OUT_FIELDS = [("dotp_ready_o", 1), ("dotp_result_valid_o", 1), ("dotp_result_id_o", 4),
              ("final_ready_o", 1), ("final_result_valid_o", 1), ("final_result_id_o", 4),
              ("final_result_rd_o", 5), ("final_result_data_o", 32)]


def hexw(v, bits):
    return format(v, "0%dx" % ((bits + 3) // 4))


def parse_header(f):
    scope, ids = [], {}
    want = {path: (key, w) for key, (path, w) in SIGNALS.items()}
    for line in f:
        t = line.split()
        if not t:
            continue
        if t[0] == "$scope":
            scope.append(t[2])
        elif t[0] == "$upscope":
            scope.pop()
        elif t[0] == "$var":
            path = ".".join(scope + [t[4]])
            if path in want:
                key, w = want[path]
                if int(t[2]) != w:
                    sys.exit(f"vcd2stim: {path} has width {t[2]}, expected {w}")
                ids.setdefault(t[3], []).append(key)
        elif t[0] == "$enddefinitions":
            break
    found = {k for keys in ids.values() for k in keys}
    missing = [SIGNALS[k][0] for k in SIGNALS if k not in found]
    if missing:
        sys.exit("vcd2stim: signals not in the VCD:\n  " + "\n  ".join(missing))
    return ids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vcd")
    ap.add_argument("out")
    ap.add_argument("--source", default="")
    ap.add_argument("--json")
    args = ap.parse_args()

    with open(args.vcd) as f:
        ids = parse_header(f)
        clk_id = next(i for i, ks in ids.items() if "clk" in ks)
        val = {k: None for k in SIGNALS}
        lines = []
        cov = dict(cycles=0, reset_cycles=0, dotp_starts=0, mailbox_pushes=0, final_starts=0,
                   final_results=0, mailbox_max_occupancy=0, mailbox_full_cycles=0,
                   mailbox_full_and_dotp_valid_cycles=0, dotp_valid_not_ready_cycles=0,
                   final_valid_not_ready_cycles=0)
        occ = 0

        def sample():
            nonlocal occ
            v = val
            if any(x is None for x in v.values()):
                sys.exit("vcd2stim: a signal has no value at the first rising edge")
            d_valid = v["d_valid_raw"] & (1 - v["mb_full"])
            f_ready = v["mb_valid"] & v["f_eng_ready"]
            cyc = len(lines)
            # cross-checks of the boundary reading
            if v["x_d_eng_rr"] != ((1 - v["mb_full"]) & v["d_rr_xif"]):
                sys.exit(f"vcd2stim: cycle {cyc}: dotp result_ready_i != !mailbox_full && dotp_result_ready_xif")
            if v["x_f_eng_start"] != (v["f_head_ok"] & f_ready):
                sys.exit(f"vcd2stim: cycle {cyc}: final start_i != final_pending_head_ok && final_ready")
            if v["x_f_eng_rr"] != v["f_rr"]:
                sys.exit(f"vcd2stim: cycle {cyc}: final result_ready_i != final_result_ready")
            ins = [v["rst_ni"], v["d_start"], v["d_id"], v["d_rs1"], v["d_rs2"], v["d_rs3"], v["d_rr_xif"],
                   v["f_head_ok"], v["f_id"], v["f_rd"], v["f_rs1"], v["f_rs2"], v["f_rr"]]
            outs = [v["d_ready"], d_valid, v["d_res_id"], f_ready, v["f_valid"], v["f_res_id"],
                    v["f_res_rd"], v["f_res_data"]]
            lines.append(" ".join([str(cyc)] + [hexw(x, w) for x, (_, w) in zip(ins, IN_FIELDS)]
                                  + [hexw(x, w) for x, (_, w) in zip(outs, OUT_FIELDS)]))
            # coverage (what this edge does)
            cov["cycles"] += 1
            if not v["rst_ni"]:
                cov["reset_cycles"] += 1
                return
            push = d_valid & v["d_rr_xif"]
            pop = v["x_f_eng_start"]
            cov["dotp_starts"] += v["d_start"]
            cov["mailbox_pushes"] += push
            cov["final_starts"] += pop
            cov["final_results"] += v["f_valid"] & v["f_rr"]
            cov["mailbox_full_cycles"] += v["mb_full"]
            cov["mailbox_full_and_dotp_valid_cycles"] += v["mb_full"] & v["d_valid_raw"]
            cov["dotp_valid_not_ready_cycles"] += d_valid & (1 - v["d_rr_xif"])
            cov["final_valid_not_ready_cycles"] += v["f_valid"] & (1 - v["f_rr"])
            occ += push - pop
            cov["mailbox_max_occupancy"] = max(cov["mailbox_max_occupancy"], occ)

        changes = []

        def flush():
            new_clk = None
            for i, x in changes:
                if i == clk_id:
                    new_clk = x
            if new_clk == 1 and val["clk"] == 0:
                sample()
            for i, x in changes:
                for k in ids[i]:
                    val[k] = x
            changes.clear()

        for line in f:
            c = line[0]
            if c == "#":
                flush()
            elif c in "01":
                i = line[1:].strip()
                if i in ids:
                    changes.append((i, int(c)))
            elif c == "b":
                bits, i = line[1:].split()
                if i in ids:
                    if any(ch not in "01" for ch in bits):
                        sys.exit(f"vcd2stim: non-binary value {bits} for {ids[i]}")
                    changes.append((i, int(bits, 2)))
            elif c in "xzXZ":
                i = line[1:].strip()
                if i in ids:
                    sys.exit(f"vcd2stim: x/z value for {ids[i]}")
        flush()

    if not lines:
        sys.exit("vcd2stim: no rising clock edges found")
    with open(args.out, "w") as o:
        o.write(f"# vcd2stim.py source={args.source} vcd={args.vcd} cycles={len(lines)}\n")
        o.write("# cycle " + " ".join(n for n, _ in IN_FIELDS) + " | " + " ".join(n for n, _ in OUT_FIELDS) + "\n")
        o.write("\n".join(lines) + "\n")
    cov["source"] = args.source
    print(f"vcd2stim: {args.source}: " + ", ".join(f"{k} {v}" for k, v in cov.items() if k != "source"))
    if args.json:
        with open(args.json, "w") as j:
            json.dump(cov, j, indent=1)


if __name__ == "__main__":
    main()
