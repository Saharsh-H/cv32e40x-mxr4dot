#!/usr/bin/env bash
#==============================================================================
# run.sh - one standalone synthesis / place-and-route run (Genus 21.10, Innovus 23.13, nangate45)
#------------------------------------------------------------------------------
#   syn/cadence/run.sh <design> <period_ns> [prep|syn|pnr|all]      (default all)
#   syn/cadence/run.sh smoke      start Genus and Innovus on a one-line script each,
#                                 print their versions (no design, no library needed)
#
#   <design>  fp4 | fp8 | m2 | dotp | mxfinal | pair   (top = mx_syn_<design>)
#   stages    prep  write the per-run files only (no tools; checks inputs)
#             syn   prep + Genus
#             pnr   Innovus on an existing syn result of the same run
#             all   syn + pnr
#
# Environment:
#   MX_NANGATE_DIR  (required except for smoke) directory with
#                   lib/NangateOpenCellLibrary_typical.lib and
#                   lef/NangateOpenCellLibrary.{tech,macro}.lef (the collaborator's library/ layout)
#   GENUS_CMD, INNOVUS_CMD  (optional) override the tool invocations below
#
# Output: syn/results/<design>/p<period>/ (gitignored): sources.txt, mx.sdc (this
# run's copy, period filled in), run_config.tcl, run_info.txt, genus/, innovus/;
# genus/reports/mx_summary.txt and innovus/reports/mx_summary.txt (key value lines,
# read by sweep.sh).
#
#------------------------------------------------------------------------------
# PERIOD SWEEP: syn/cadence/sweep.sh (definition in its header)
#------------------------------------------------------------------------------
# UNVERIFIED (no Cadence tools here): the genus/innovus command lines below.
#==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DESIGNS="fp4 fp8 m2 dotp mxfinal pair"

usage() { sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
GENUS_CMD="${GENUS_CMD:-genus -batch -files}"        # UNVERIFIED invocation
INNOVUS_CMD="${INNOVUS_CMD:-innovus -batch -files}"  # UNVERIFIED invocation

#---- smoke: can the tools be started this way at all? ------------------------------
# PASS for a tool = exit code 0 and its MX_SMOKE line in the output. stdin is
# /dev/null so a tool that drops to its prompt after the script ends returns.
if [ "${1:-}" = smoke ]; then
  SM="$ROOT/syn/results/smoke"; mkdir -p "$SM"
  echo 'set v "?"; catch {set v [get_db program_version]}; puts "MX_SMOKE genus version $v"; exit' > "$SM/genus_smoke.tcl"
  echo 'set v "?"; catch {set v [getVersion]}; puts "MX_SMOKE innovus version $v"; exit' > "$SM/innovus_smoke.tcl"
  fail=0
  for t in genus innovus; do
    cmd="$GENUS_CMD"; [ $t = innovus ] && cmd="$INNOVUS_CMD"
    echo "== $t: $(command -v "${cmd%% *}" || echo "'${cmd%% *}' not on PATH")"
    if ! command -v "${cmd%% *}" >/dev/null; then fail=1; continue; fi
    rc=0
    (cd "$SM" && $cmd "$SM/${t}_smoke.tcl" -log "$SM/${t}_smoke" < /dev/null) > "$SM/${t}_smoke.out" 2>&1 || rc=$?
    grep -m1 -iE 'version' "$SM/${t}_smoke.out" | sed 's/^/   banner: /' || true
    if [ $rc = 0 ] && grep -q '^MX_SMOKE' "$SM/${t}_smoke.out"; then
      echo "   PASS (exit 0): $(grep -m1 '^MX_SMOKE' "$SM/${t}_smoke.out")"
    else
      echo "   FAIL (exit $rc): see $SM/${t}_smoke.out"; fail=1
    fi
  done
  exit $fail
fi

[ $# -ge 2 ] || usage
design="$1"; period="$2"; stage="${3:-all}"
case " $DESIGNS " in *" $design "*) ;; *) echo "run.sh: unknown design '$design'" >&2; usage;; esac
case "$stage" in prep|syn|pnr|all) ;; *) echo "run.sh: unknown stage '$stage'" >&2; usage;; esac
[[ "$period" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "run.sh: period must be a number in ns" >&2; exit 1; }

: "${MX_NANGATE_DIR:?run.sh: set MX_NANGATE_DIR to the nangate45 library directory (with lib/ and lef/)}"
LIB_DIR="$MX_NANGATE_DIR/lib"
LEF_DIR="$MX_NANGATE_DIR/lef"
LIB_FILES="NangateOpenCellLibrary_typical.lib"
# tech.lef + macro.lef only (user, 23 Oct): the original cells with their antenna data.
# The collaborator's setup.g also read macro.mod.lef, which defines the same 134 macros
# again (plus TAPCELL_X1) without antenna data. Each macro must be defined once: checked
# below on the files, and again by innovus.tcl on the Innovus log.
LEF_FILES="NangateOpenCellLibrary.tech.lef NangateOpenCellLibrary.macro.lef"
for f in $LIB_FILES; do [ -f "$LIB_DIR/$f" ] || { echo "run.sh: missing $LIB_DIR/$f" >&2; exit 1; }; done
for f in $LEF_FILES; do [ -f "$LEF_DIR/$f" ] || { echo "run.sh: missing $LEF_DIR/$f" >&2; exit 1; }; done
dup_macros="$(for f in $LEF_FILES; do awk '$1=="MACRO" {print $2}' "$LEF_DIR/$f"; done | sort | uniq -d)"
[ -z "$dup_macros" ] || { echo "run.sh: $(echo "$dup_macros" | wc -l) macros defined more than once in the LEF list, e.g. $(echo "$dup_macros" | head -3 | tr '\n' ' ')" >&2; exit 1; }

ptag="$(printf '%.3f' "$period")"
OUT="$ROOT/syn/results/$design/p$ptag"
top="mx_syn_$design"
mkdir -p "$OUT/genus" "$OUT/innovus"

#---- sources: filelist -> absolute paths, each must exist ---------------------------
flist="$ROOT/syn/filelists/$design.f"
grep -vE '^\s*(#|$)' "$flist" | sed "s|^|$ROOT/|" > "$OUT/sources.txt"
while read -r src; do [ -f "$src" ] || { echo "run.sh: $flist names a missing file: $src" >&2; exit 1; }; done < "$OUT/sources.txt"

#---- per-run SDC: the only change is the period line ---------------------------------
sdc_src="$ROOT/syn/constraints/mx.sdc"
sed "s|^set MX_PERIOD_NS .*|set MX_PERIOD_NS $period|" "$sdc_src" > "$OUT/mx.sdc"
[ "$(grep -c "^set MX_PERIOD_NS $period\$" "$OUT/mx.sdc")" = 1 ] || { echo "run.sh: period line not found in $sdc_src" >&2; exit 1; }
unc_post="$(awk '$1=="set" && $2=="MX_UNC_SETUP_POSTCTS" {print $3}' "$sdc_src")"
[[ "$unc_post" =~ ^[0-9.]+$ ]] || { echo "run.sh: MX_UNC_SETUP_POSTCTS not found in $sdc_src" >&2; exit 1; }

#---- run configuration read by genus.tcl / innovus.tcl ------------------------------
{
  echo "# written by syn/cadence/run.sh - do not edit"
  echo "set MX_DESIGN      $design"
  echo "set MX_TOP         $top"
  echo "set MX_PERIOD_NS   $period"
  echo "set MX_SOURCES     [list $(tr '\n' ' ' < "$OUT/sources.txt")]"
  echo "set MX_SDC         $OUT/mx.sdc"
  echo "set MX_LIB_DIR     $LIB_DIR"
  echo "set MX_LEF_DIR     $LEF_DIR"
  echo "set MX_LIB_FILES   [list $LIB_FILES]"
  echo "set MX_LEF_FILES   [list $LEF_FILES]"
  echo "set MX_PWR_NET     VDD"
  echo "set MX_GND_NET     VSS"
  echo "set MX_UNC_SETUP_POSTCTS $unc_post"
  echo "set MX_GENUS_DIR   $OUT/genus"
  echo "set MX_INNOVUS_DIR $OUT/innovus"
  echo "set MX_INNOVUS_LOG $OUT/innovus/innovus.log"
  echo "set MX_N_CRIT_PATHS    100"
  echo "set MX_N_WORST_PER_PATH 3"
} > "$OUT/run_config.tcl"
export MX_RUN_CONFIG="$OUT/run_config.tcl"

#---- provenance -----------------------------------------------------------------------
{
  echo "design $design  top $top  period $period ns  stage $stage"
  echo "date $(date -Iseconds)  host $(hostname)"
  if git -C "$ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
    echo "repo commit $(git -C "$ROOT" rev-parse --short HEAD)$( [ -n "$(git -C "$ROOT" status --porcelain)" ] && echo -dirty)"
  elif [ -f "$ROOT/MX_COMMIT" ]; then
    # tarball from git archive (GPU_PC_STEPS.md); edits made after unpacking are not detected
    echo "repo commit $(cut -c1-8 "$ROOT/MX_COMMIT") (tarball)"
  else
    echo "repo commit unknown"
  fi
  echo "library $MX_NANGATE_DIR"
  for f in $LIB_FILES; do echo "sha256 $(sha256sum "$LIB_DIR/$f")"; done
  for f in $LEF_FILES; do echo "sha256 $(sha256sum "$LEF_DIR/$f")"; done
} > "$OUT/run_info.txt"

# Forward-reference check (needs Verilator; run it in WSL if it is not here).
if command -v verilator >/dev/null 2>&1; then
  "$ROOT/tb/scripts/fwdref_check.sh" "$ROOT" > "$OUT/fwdref_check.txt" 2>&1 \
    || { cat "$OUT/fwdref_check.txt" >&2; echo "run.sh: forward-reference check failed" >&2; exit 1; }
else
  echo "fwdref_check: not run here (no verilator) - run tb/scripts/fwdref_check.sh before copying" >> "$OUT/run_info.txt"
fi

echo "run.sh: $design @ $period ns -> $OUT"
[ "$stage" = prep ] && exit 0

if [ "$stage" = syn ] || [ "$stage" = all ]; then
  command -v "${GENUS_CMD%% *}" >/dev/null || { echo "run.sh: '${GENUS_CMD%% *}' not on PATH" >&2; exit 1; }
  rm -f "$OUT/genus/reports/mx_summary.txt" "$OUT/genus"/genus.log* "$OUT/genus"/genus.cmd*
  (cd "$OUT/genus" && $GENUS_CMD "$ROOT/syn/cadence/genus.tcl" -log "$OUT/genus/genus" < /dev/null)
  [ -f "$OUT/genus/outputs/${top}_synth.v" ] || { echo "run.sh: Genus produced no netlist" >&2; exit 1; }
  [ -f "$OUT/genus/reports/mx_summary.txt" ] || { echo "run.sh: Genus stopped before the end (no mx_summary.txt)" >&2; exit 1; }
fi
if [ "$stage" = pnr ] || [ "$stage" = all ]; then
  [ -f "$OUT/genus/outputs/${top}_synth.v" ] || { echo "run.sh: run the syn stage first" >&2; exit 1; }
  command -v "${INNOVUS_CMD%% *}" >/dev/null || { echo "run.sh: '${INNOVUS_CMD%% *}' not on PATH" >&2; exit 1; }
  # old logs removed so innovus.tcl's LEF check can only read this run's log
  rm -f "$OUT/innovus/reports/mx_summary.txt" "$OUT/innovus"/innovus.log* "$OUT/innovus"/innovus.cmd*
  (cd "$OUT/innovus" && $INNOVUS_CMD "$ROOT/syn/cadence/innovus.tcl" -log "$OUT/innovus/innovus" < /dev/null)
  [ -f "$OUT/innovus/reports/mx_summary.txt" ] || { echo "run.sh: Innovus stopped before the end (no mx_summary.txt); see $OUT/innovus/innovus.log" >&2; exit 1; }
fi
echo "run.sh: done ($stage). Reports: $OUT/genus/reports, $OUT/innovus/reports"
