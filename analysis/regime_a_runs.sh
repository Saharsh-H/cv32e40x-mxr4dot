#!/bin/bash
# Task 5 regime A: run the K=4096 loop programs at every data-port setting and
# make the regime-A tables (analysis/bw_model.py regime-a).
#
#   analysis/regime_a_runs.sh [--md]          (from the repo root)
#
# Formats mxfp4, mxfp8, mxfp4r; settings ideal, read latency 1-5 (+dwait=n), one
# data access per 2 and per 4 cycles (+dgnt=1, +dgnt=3). Every run uses +gcount
# (data-port grants per MARK region, tb/mem_model.sv). The ideal run is repeated
# without +gcount to show that the counter does not change timing. Logs and JSONs
# go to tb/build/regime_a/ (from tb/scripts/loop_report.py --json-out); a run that
# does not end in "PROGRAM EXIT code=0" stops the script.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/tb/build/regime_a
mkdir -p "$OUT"
SETTINGS="ideal dwait=1 dwait=2 dwait=3 dwait=4 dwait=5 dgnt=1 dgnt=3"

run() {   # run <prog> <name> <plusargs>
  make -s -C "$ROOT/tb" loop PROG="$1" LOOP_ARGS="$3" > "$OUT/$1_$2.log" 2>&1 || true
  grep -q 'PROGRAM EXIT code=0 ' "$OUT/$1_$2.log" || { echo "FAIL: $1 $2 (see $OUT/$1_$2.log)" >&2; exit 1; }
}

for p in mxfp4 mxfp8 mxfp4r; do
  case $p in mxfp4) mx=10:256,20:256 ;; *) mx=10:512,20:512 ;; esac
  run "$p" ideal_nogcount ""
  for s in $SETTINGS; do
    if [ "$s" = ideal ]; then mode=ideal; n=0; args=+gcount
    else mode=${s%%=*}; n=${s#*=}; args="+gcount +$s"; fi
    run "$p" "$s" "$args"
    python3 "$ROOT/tb/scripts/loop_report.py" "$OUT/${p}_$s.log" --k 4096 --mx "$mx" \
      --json-out "$OUT/${p}_$s.json" --meta "format=$p,mode=$mode,n=$n" > "$OUT/${p}_$s.report.txt"
  done
  # +gcount must not change timing: the MARK lines of the two ideal runs must be identical
  if ! diff <(grep '^\[MARK' "$OUT/${p}_ideal_nogcount.log") <(grep '^\[MARK' "$OUT/${p}_ideal.log") > /dev/null; then
    echo "FAIL: $p ideal MARK cycles differ with and without +gcount" >&2; exit 1
  fi
done

python3 "$ROOT/analysis/bw_model.py" regime-a "$@" "$OUT"/*.json
