#!/usr/bin/env bash
#==============================================================================
# pair_replay.sh - capture-and-replay output check of syn/wrappers/mx_syn_pair.sv
#------------------------------------------------------------------------------
#   tb/scripts/pair_replay.sh [--no-capture]       (from the repo root or anywhere)
#
# 1. Capture: runs the existing system targets with a VCD - make full, make
#    stream, make loop PROG=mxfp4r LOOP_TRACE=1 (NACC=1 and NACC=4 kernels in one
#    run) - and cuts the pair boundary out of each VCD (tb/scripts/vcd2stim.py,
#    which also cross-checks the boundary and prints coverage counts).
#    --no-capture reuses the stimulus files of the previous run.
# 2. Replay: builds tb/pair_replay/tb_pair_replay.sv + syn/filelists/pair.f and
#    replays every source; every output, every cycle. PASS = 0 valid-cycle and
#    0 invalid-cycle mismatches.
# 3. Broken cases (each on a copy; the repo is not touched), each must be caught:
#    a  one expected final_result_data_o bit flipped on a valid cycle (loop)
#       -> exactly that 1 mismatch
#    b  one dotp_rs3_i bit flipped on one mxresdot start, chosen with the golden
#       models so that pair's final result changes (loop) -> mismatches only on
#       final_result_data_o, equal to the golden flipped value: valid-cycle ones on
#       that pair's result cycles, invalid-cycle ones on the following cycles where
#       the captured output still holds that result (the output register holds it)
#    c  every input delayed by one cycle (loop) -> FAIL
#    d  scratch wrapper with MAILBOX_DEPTH = 2 -> FAIL on stream (mailbox reaches
#       4); loop (max 1 entry) is reported as the known limit of that source
#    e  scratch wrapper without !mailbox_full in dotp_result_valid_o (stream, the
#       source with full-mailbox cycles) -> FAIL only if some cycle has a DOTP
#       result valid while the mailbox is full; the count is printed with it
#
# Scope: an RTL-level check of the wrapper; the synthesised netlist is not
# checked. The xif's order-queue head gating of the XIF result channel
# (mxdotp_xif.sv:966-988, :889) is outside the pair: it reaches the pair only
# through the captured *_result_ready_i inputs, and neither this check nor the
# wrapper's synthesis covers it.
#
# Outputs: tb/build/pair_replay/ (gitignored). Exit 0 = every expectation met.
#==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TB="$ROOT/tb"
O="$TB/build/pair_replay"
mkdir -p "$O"
cd "$ROOT"
PY="python3 -I"
fail=0
note() { echo "pair_replay: $*"; }
die() { echo "pair_replay: $*" >&2; exit 2; }

#---- 1. capture -----------------------------------------------------------------------
if [ "${1:-}" != --no-capture ]; then
  (cd "$TB" && make full > "$O/cap_full.log" 2>&1) || die "make full failed ($O/cap_full.log)"
  grep -q 'Summary: pass=1 fail=0' "$O/cap_full.log" || die "make full did not pass"
  (cd "$TB" && make stream > "$O/cap_stream.log" 2>&1) || die "make stream failed ($O/cap_stream.log)"
  (cd "$TB" && make loop PROG=mxfp4r LOOP_TRACE=1 > "$O/cap_loop.log" 2>&1) || die "make loop PROG=mxfp4r failed"
  grep -q 'PROGRAM EXIT code=0 ' "$O/cap_loop.log" || die "mxfp4r loop did not exit 0"
  for s in full:"$TB/tb_mxdotp_core.vcd" stream:"$TB/build/stream/tb_mxdotp_core.vcd" loop:"$TB/build/loop/tb_mxdotp_core.vcd"; do
    n=${s%%:*}; v=${s#*:}
    $PY "$TB/scripts/vcd2stim.py" "$v" "$O/stim_$n.txt" --source "$n" --json "$O/cov_$n.json" || die "vcd2stim failed on $n"
  done
fi
for n in full stream loop; do [ -s "$O/stim_$n.txt" ] || die "no $O/stim_$n.txt (run without --no-capture)"; done
cov() { $PY -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$O/cov_$1.json" "$2"; }

#---- build ------------------------------------------------------------------------------
SRCS=$(grep -vE '^\s*(#|$)' syn/filelists/pair.f)
build() {   # build <name> <wrapper file>
  local srcs; srcs=$(echo "$SRCS" | grep -v 'syn/wrappers/mx_syn_pair.sv'; echo "$2")
  verilator -sv --binary --Wno-fatal -O3 --timing -Wall -Wno-UNOPTFLAT -Wno-BLKANDNBLK \
    -Irtl/include -Irtl/mxdotp --top-module tb_pair_replay --Mdir "$O/obj_$1" -o Vreplay \
    $srcs tb/pair_replay/tb_pair_replay.sv > "$O/build_$1.log" 2>&1 || die "build $1 failed ($O/build_$1.log)"
}
replay() {  # replay <build> <stim> <tag> ; prints the REPLAY line, returns the exit code
  "$O/obj_$1/Vreplay" +stim="$2" +mm="$O/mm_$3.txt" > "$O/replay_$3.log" 2>&1
  local rc=$?
  grep -E '^REPLAY' "$O/replay_$3.log" || echo "REPLAY (no summary line; see $O/replay_$3.log)"
  return $rc
}
build base syn/wrappers/mx_syn_pair.sv
note "replay build: $(grep -c '%Warning' "$O/build_base.log") Verilator warnings, $(grep -c '%Warning.*tb_pair_replay' "$O/build_base.log") in tb_pair_replay.sv"

#---- 2. the check -------------------------------------------------------------------------
declare -a TABLE
for n in full stream loop; do
  line=$(replay base "$O/stim_$n.txt" "base_$n"); rc=$?
  [ $rc = 0 ] || fail=1
  TABLE+=("check   $n: $line  [expected PASS]")
done

#---- 3. broken cases ------------------------------------------------------------------------
expect_fail() {  # expect_fail <label> <rc> <line>
  if [ "$2" != 0 ]; then TABLE+=("$1: $3  [expected FAIL: caught]"); else TABLE+=("$1: $3  [expected FAIL: NOT CAUGHT]"); fail=1; fi
}
$PY tb/scripts/pair_replay_cases.py make-a "$O/stim_loop.txt" "$O/stim_case_a.txt" "$O/expect_a.json" || die "make-a"
line=$(replay base "$O/stim_case_a.txt" case_a); rc=$?; expect_fail "case a  loop" $rc "$line"
$PY tb/scripts/pair_replay_cases.py check "$O/expect_a.json" "$O/mm_case_a.txt" || fail=1

$PY tb/scripts/pair_replay_cases.py make-b "$O/stim_loop.txt" "$O/stim_case_b.txt" "$O/expect_b.json" || die "make-b"
line=$(replay base "$O/stim_case_b.txt" case_b); rc=$?; expect_fail "case b  loop" $rc "$line"
$PY tb/scripts/pair_replay_cases.py check "$O/expect_b.json" "$O/mm_case_b.txt" || fail=1

$PY tb/scripts/pair_replay_cases.py make-c "$O/stim_loop.txt" "$O/stim_case_c.txt" || die "make-c"
line=$(replay base "$O/stim_case_c.txt" case_c); rc=$?; expect_fail "case c  loop" $rc "$line"

sed 's/parameter int MAILBOX_DEPTH = 4 /parameter int MAILBOX_DEPTH = 2 /' syn/wrappers/mx_syn_pair.sv > "$O/mx_syn_pair_depth2.sv"
[ "$(diff syn/wrappers/mx_syn_pair.sv "$O/mx_syn_pair_depth2.sv" | grep -c '^>')" = 1 ] || die "case d edit did not apply exactly once"
build depth2 "$O/mx_syn_pair_depth2.sv"
line=$(replay depth2 "$O/stim_stream.txt" case_d_stream); rc=$?; expect_fail "case d  stream (max occupancy $(cov stream mailbox_max_occupancy))" $rc "$line"
line=$(replay depth2 "$O/stim_loop.txt" case_d_loop); rc=$?
TABLE+=("case d  loop (max occupancy $(cov loop mailbox_max_occupancy)): $line  [known limit of this source: $( [ $rc = 0 ] && echo 'not caught, as predicted' || echo 'caught')]")

sed 's/assign dotp_result_valid_o = dotp_engine_result_valid \&\& !mailbox_full;/assign dotp_result_valid_o = dotp_engine_result_valid;/' \
  syn/wrappers/mx_syn_pair.sv > "$O/mx_syn_pair_nofull.sv"
[ "$(diff syn/wrappers/mx_syn_pair.sv "$O/mx_syn_pair_nofull.sv" | grep -c '^>')" = 1 ] || die "case e edit did not apply exactly once"
build nofull "$O/mx_syn_pair_nofull.sv"
fv=$(cov stream mailbox_full_and_dotp_valid_cycles)
line=$(replay nofull "$O/stim_stream.txt" case_e_stream); rc=$?
if [ "$fv" -gt 0 ]; then expect_fail "case e  stream (full cycles $(cov stream mailbox_full_cycles), full+valid $fv)" $rc "$line"
else TABLE+=("case e  stream (full cycles $(cov stream mailbox_full_cycles), full+valid $fv): $line  [NOT OBSERVABLE in this source: the edit changes an output only when a DOTP result is valid while the mailbox is full]"); fi

#---- summary --------------------------------------------------------------------------------
echo
echo "================ pair_replay summary ================"
for n in full stream loop; do note "coverage $n: $($PY -c "import json,sys; d=json.load(open(sys.argv[1])); print(', '.join(f'{k} {v}' for k,v in d.items() if k!='source'))" "$O/cov_$n.json")"; done
printf '%s\n' "${TABLE[@]}"
[ $fail = 0 ] && note "ALL EXPECTATIONS MET" || note "SOME EXPECTATION NOT MET"
exit $fail
