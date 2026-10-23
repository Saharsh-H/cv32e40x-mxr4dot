#!/usr/bin/env bash
#==============================================================================
# run.sh - one standalone synthesis / place-and-route run (Genus 21.10, Innovus 23.13, nangate45)
#------------------------------------------------------------------------------
#   syn/cadence/run.sh <design> <period_ns> [prep|syn|pnr|all]      (default all)
#
#   <design>  fp4 | fp8 | m2 | dotp | mxfinal | pair   (top = mx_syn_<design>)
#   stages    prep  write the per-run files only (no tools; checks inputs)
#             syn   prep + Genus
#             pnr   Innovus on an existing syn result of the same run
#             all   syn + pnr
#
# Environment:
#   MX_NANGATE_DIR  (required) directory with lib/NangateOpenCellLibrary_typical.lib
#                   and lef/NangateOpenCellLibrary.{tech,macro.mod,macro}.lef
#                   (the collaborator's library/ layout)
#   GENUS_CMD, INNOVUS_CMD  (optional) override the tool invocations below
#
# Output: syn/results/<design>/p<period>/ (gitignored): sources.txt, mx.sdc (this
# run's copy, period filled in), run_config.tcl, run_info.txt, genus/, innovus/.
#
#------------------------------------------------------------------------------
# PERIOD SWEEP (proposal, 23 Oct 2026 - not yet run)
#------------------------------------------------------------------------------
# Closure (user, 23 Oct): all paths including I/O, post-route setup WNS >= 0 and
# hold WNS >= 0 (innovus timeDesign summaries). reg2reg-only is reported as a
# separate, labelled diagnostic, never as the result.
# Start, per design: 1.2 x the period of the old Table V Fmax (those runs were
# constrained at 1 ns, so this is only a starting point), rounded to 0.05 ns:
#   fp4  2.50   (480.6 MHz -> 2.081 ns)     m2      2.75 (439.2 -> 2.277)
#   fp8  2.85   (422.7 -> 2.366)             dotp    1.30 (915.5 -> 1.092)
#   mxfinal 2.40 (501.7 -> 1.993)            pair    2.40 (its slower half, mxfinal)
# Step: run 'all' at the start; if it closes, go down in 0.10 ns steps until a
# run fails; if not, go up in 0.10 ns steps until one closes. Then bisect the
# last failing / first closing pair until they are <= 0.02 ns apart (periods
# rounded to 0.005 ns). Result: Fmax = 1 / (tightest closing period), with the
# bracket width stated. Every run is kept and reported; if a looser period fails
# after a tighter one closed, that is reported, and the tightest period whose
# looser runs all closed is used.
# Area table: every design at one common period = the largest of the six
# tightest closing periods, rounded up to 0.1 ns. Area-frequency curve: each
# design at 1.0 / 1.25 / 1.5 / 2.0 x its own tightest closing period.
#
# UNVERIFIED (no Cadence tools here): the genus/innovus command lines below.
#==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DESIGNS="fp4 fp8 m2 dotp mxfinal pair"

usage() { sed -n '4,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
[ $# -ge 2 ] || usage
design="$1"; period="$2"; stage="${3:-all}"
case " $DESIGNS " in *" $design "*) ;; *) echo "run.sh: unknown design '$design'" >&2; usage;; esac
case "$stage" in prep|syn|pnr|all) ;; *) echo "run.sh: unknown stage '$stage'" >&2; usage;; esac
[[ "$period" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "run.sh: period must be a number in ns" >&2; exit 1; }

: "${MX_NANGATE_DIR:?run.sh: set MX_NANGATE_DIR to the nangate45 library directory (with lib/ and lef/)}"
LIB_DIR="$MX_NANGATE_DIR/lib"
LEF_DIR="$MX_NANGATE_DIR/lef"
LIB_FILES="NangateOpenCellLibrary_typical.lib"
# The collaborator's list and order (setup.g). macro.mod.lef and macro.lef define the
# same 134 macros (macro.mod.lef adds TAPCELL_X1, macro.lef has the antenna data);
# which definition Innovus keeps when both are read is UNVERIFIED.
LEF_FILES="NangateOpenCellLibrary.tech.lef NangateOpenCellLibrary.macro.mod.lef NangateOpenCellLibrary.macro.lef"
for f in $LIB_FILES; do [ -f "$LIB_DIR/$f" ] || { echo "run.sh: missing $LIB_DIR/$f" >&2; exit 1; }; done
for f in $LEF_FILES; do [ -f "$LEF_DIR/$f" ] || { echo "run.sh: missing $LEF_DIR/$f" >&2; exit 1; }; done

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
  echo "set MX_N_CRIT_PATHS    100"
  echo "set MX_N_WORST_PER_PATH 3"
} > "$OUT/run_config.tcl"
export MX_RUN_CONFIG="$OUT/run_config.tcl"

#---- provenance -----------------------------------------------------------------------
{
  echo "design $design  top $top  period $period ns  stage $stage"
  echo "date $(date -Iseconds)  host $(hostname)"
  echo "repo commit $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)$( [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] && echo -dirty)"
  echo "library $MX_NANGATE_DIR"
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

GENUS_CMD="${GENUS_CMD:-genus -batch -files}"        # UNVERIFIED invocation
INNOVUS_CMD="${INNOVUS_CMD:-innovus -batch -files}"  # UNVERIFIED invocation

if [ "$stage" = syn ] || [ "$stage" = all ]; then
  command -v "${GENUS_CMD%% *}" >/dev/null || { echo "run.sh: '${GENUS_CMD%% *}' not on PATH" >&2; exit 1; }
  (cd "$OUT/genus" && $GENUS_CMD "$ROOT/syn/cadence/genus.tcl" -log "$OUT/genus/genus")
  [ -f "$OUT/genus/outputs/${top}_synth.v" ] || { echo "run.sh: Genus produced no netlist" >&2; exit 1; }
fi
if [ "$stage" = pnr ] || [ "$stage" = all ]; then
  [ -f "$OUT/genus/outputs/${top}_synth.v" ] || { echo "run.sh: run the syn stage first" >&2; exit 1; }
  command -v "${INNOVUS_CMD%% *}" >/dev/null || { echo "run.sh: '${INNOVUS_CMD%% *}' not on PATH" >&2; exit 1; }
  (cd "$OUT/innovus" && $INNOVUS_CMD "$ROOT/syn/cadence/innovus.tcl" -log "$OUT/innovus/innovus")
fi
echo "run.sh: done ($stage). Reports: $OUT/genus/reports, $OUT/innovus/reports"
