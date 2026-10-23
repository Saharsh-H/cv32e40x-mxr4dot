#!/usr/bin/env bash
#==============================================================================
# sweep.sh - find one design's tightest closing period with run.sh
#------------------------------------------------------------------------------
#   syn/cadence/sweep.sh <design> syn [start_ns]   phase 1: synthesis only
#   syn/cadence/sweep.sh <design> pnr [start_ns]   phase 2: place and route near
#                                                  the phase-1 limit
#
# Same environment as run.sh (MX_NANGATE_DIR, GENUS_CMD, INNOVUS_CMD), plus
#   MX_GENUS_SLACK_TO_NS  factor from Genus' slack unit to ns (default 0.001,
#                         i.e. Genus reports ps - UNVERIFIED, confirm on the first run)
#   MX_SWEEP_MAX_STEPS    max 0.10 ns steps in one direction (default 15)
#
# Output (gitignored): syn/results/<design>/sweep_<phase>.tsv (every point:
# period, slacks, verdict, new/reused), sweep_<phase>.log (run.sh output),
# sweep_<phase>.result (the answer, key value lines).
#
#------------------------------------------------------------------------------
# DEFINITION (user, 23 Oct 2026)
#------------------------------------------------------------------------------
# Phase 1 (syn): approximate limit from synthesis only. A point closes if
#   Genus' worst setup slack over all paths (I/O included) >= 0. This is an
#   estimate that only steers phase 2; it is never reported as an Fmax.
# Phase 2 (pnr): place and route only near the phase-1 limit, starting at it.
#   A point closes if post-route setup WNS >= 0 and hold WNS >= 0, all paths
#   including I/O (the closure rule). Each point is a full run at that period
#   (synthesis is constraint-driven, so it is redone per period; a phase-1
#   synthesis at the same period and commit is reused).
# Search, both phases: start at the start period (phase 1 default: 1.2 x the
#   period of the old Table V Fmax, rounded to 0.05 ns - those runs were
#   constrained at 1 ns, so this is only a starting point:
#     fp4 2.50 (480.6 MHz -> 2.081 ns)   m2 2.75 (439.2 -> 2.277)
#     fp8 2.85 (422.7 -> 2.366)          dotp 1.30 (915.5 -> 1.092)
#     mxfinal 2.40 (501.7 -> 1.993)      pair 2.40 (its slower half, mxfinal)
#   phase 2 default: the phase-1 limit). If it closes, go down in 0.10 ns steps
#   until a point fails; if not, go up in 0.10 ns steps until one closes. Then
#   bisect the last failing / first closing pair until they are <= 0.02 ns apart
#   (periods on a 0.005 ns grid).
# Answer: the tightest closing period whose looser points (in this sweep) all
#   closed; Fmax = 1 / that period, with the bracket stated. Every point is kept
#   in the .tsv; a closing point below a failing one is reported (nonmonotone).
# Stops (exit 1, nothing guessed) when: run.sh fails (a tool error is not a
#   timing failure), a slack is "unknown", or no bracket within the step limit.
# Not here (later, once the limits are known): the area table at the common
#   period and the area-frequency points (1.0 / 1.25 / 1.5 / 2.0 x each limit).
#==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN="$ROOT/syn/cadence/run.sh"

usage() { sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
[ $# -ge 2 ] || usage
design="$1"; phase="$2"; start="${3:-}"
case "$phase" in syn|pnr) ;; *) echo "sweep.sh: phase must be syn or pnr" >&2; usage;; esac

STEP=0.10; TOL=0.02; GRID=0.005; PMIN=0.30
MAX_STEPS="${MX_SWEEP_MAX_STEPS:-15}"
GSCALE="${MX_GENUS_SLACK_TO_NS:-0.001}"

D="$ROOT/syn/results/$design"
mkdir -p "$D"
TSV="$D/sweep_$phase.tsv"; LOG="$D/sweep_$phase.log"; RES="$D/sweep_$phase.result"

if [ -z "$start" ]; then
  if [ "$phase" = syn ]; then
    case "$design" in
      fp4) start=2.50;; fp8) start=2.85;; m2) start=2.75;;
      dotp) start=1.30;; mxfinal) start=2.40;; pair) start=2.40;;
      *) echo "sweep.sh: unknown design '$design'" >&2; exit 1;;
    esac
  else
    [ -f "$D/sweep_syn.result" ] || { echo "sweep.sh: no $D/sweep_syn.result; run phase syn first or give start_ns" >&2; exit 1; }
    start="$(awk '$1=="limit_ns" {print $2}' "$D/sweep_syn.result")"
  fi
fi
[[ "$start" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "sweep.sh: bad start period '$start'" >&2; exit 1; }

#---- helpers (awk for all arithmetic) ------------------------------------------------------
snap() { awk -v x="$1" -v g="$GRID" 'BEGIN{printf "%.3f", int(x/g+0.5)*g}'; }
add()  { awk -v x="$1" -v y="$2" 'BEGIN{printf "%.3f", x+y}'; }
gt()   { awk -v x="$1" -v y="$2" 'BEGIN{exit !(x>y+1e-9)}'; }

commit_id() {   # same rule as run.sh's run_info.txt
  if git -C "$ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
    echo "$(git -C "$ROOT" rev-parse --short HEAD)$( [ -n "$(git -C "$ROOT" status --porcelain)" ] && echo -dirty)"
  elif [ -f "$ROOT/MX_COMMIT" ]; then echo "$(cut -c1-8 "$ROOT/MX_COMMIT") (tarball)"
  else echo unknown; fi
}
COMMIT="$(commit_id)"
kv() { awk -v k="$1" '$1==k {print $2}' "$2"; }

# A run directory is reused only if it was made from the same, clean commit.
reusable() {
  local info="$1/run_info.txt"
  [ -f "$info" ] && [ "$COMMIT" != unknown ] && [[ "$COMMIT" != *-dirty ]] \
    && [ "$(sed -n 's/^repo commit //p' "$info")" = "$COMMIT" ]
}

[ -f "$TSV" ] || printf 'period_ns\tsetup_wns_ns\thold_wns_ns\tverdict\trun\tcommit\n' > "$TSV"
POINTS=""   # "period verdict" pairs of this invocation

# point <period>: sets VERDICT to closes|fails; stops the sweep on anything else.
point() {
  local p="$1" dir="$D/p$1" gs is how=new setup hold stage
  gs="$dir/genus/reports/mx_summary.txt"; is="$dir/innovus/reports/mx_summary.txt"
  if [ "$phase" = syn ]; then
    if [ -f "$gs" ] && reusable "$dir"; then how=reused
    else
      echo "== $design $p syn" >> "$LOG"
      "$RUN" "$design" "$p" syn >> "$LOG" 2>&1 || { echo "sweep.sh: run.sh $design $p syn failed; see $LOG" >&2; exit 1; }
    fi
    setup="$(kv setup_wns_raw "$gs")"; hold=-
    [[ "$setup" =~ ^-?[0-9.]+([eE][-+]?[0-9]+)?$ ]] || { echo "sweep.sh: Genus slack '$setup' at $p ns ($gs)" >&2; exit 1; }
    setup="$(awk -v x="$setup" -v s="$GSCALE" 'BEGIN{printf "%.4f", x*s}')"
    if awk -v x="$setup" 'BEGIN{exit !(x>=0)}'; then VERDICT=closes; else VERDICT=fails; fi
  else
    if [ -f "$is" ] && reusable "$dir"; then how=reused
    else
      stage=all; { [ -f "$gs" ] && reusable "$dir"; } && stage=pnr
      echo "== $design $p $stage" >> "$LOG"
      "$RUN" "$design" "$p" "$stage" >> "$LOG" 2>&1 || { echo "sweep.sh: run.sh $design $p $stage failed; see $LOG" >&2; exit 1; }
    fi
    setup="$(kv setup_wns_ns "$is")"; hold="$(kv hold_wns_ns "$is")"
    for v in "$setup" "$hold"; do
      [[ "$v" =~ ^-?[0-9.]+([eE][-+]?[0-9]+)?$ ]] || { echo "sweep.sh: Innovus slack '$v' at $p ns ($is)" >&2; exit 1; }
    done
    if awk -v s="$setup" -v h="$hold" 'BEGIN{exit !(s>=0 && h>=0)}'; then VERDICT=closes; else VERDICT=fails; fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$setup" "$hold" "$VERDICT" "$how" "$COMMIT" >> "$TSV"
  POINTS="$POINTS$p $VERDICT
"
  echo "sweep.sh: $design $phase $p ns: setup $setup hold $hold -> $VERDICT ($how)"
}

#---- search ---------------------------------------------------------------------------------
p="$(snap "$start")"; pass=""; fail=""
point "$p"
if [ "$VERDICT" = closes ]; then
  pass="$p"
  for ((i = 0; i < MAX_STEPS; i++)); do
    q="$(add "$p" -$STEP)"
    gt "$PMIN" "$q" && { echo "sweep.sh: below ${PMIN} ns without a failing point" >&2; exit 1; }
    point "$q"
    if [ "$VERDICT" = fails ]; then fail="$q"; break; fi
    pass="$q"; p="$q"
  done
else
  fail="$p"
  for ((i = 0; i < MAX_STEPS; i++)); do
    q="$(add "$p" $STEP)"
    point "$q"
    if [ "$VERDICT" = closes ]; then pass="$q"; break; fi
    fail="$q"; p="$q"
  done
fi
{ [ -n "$pass" ] && [ -n "$fail" ]; } || { echo "sweep.sh: no closing/failing bracket within $MAX_STEPS steps" >&2; exit 1; }

while gt "$(add "$pass" -"$fail")" "$TOL"; do
  mid="$(snap "$(awk -v a="$pass" -v b="$fail" 'BEGIN{print (a+b)/2}')")"
  { [ "$mid" = "$pass" ] || [ "$mid" = "$fail" ]; } && break
  point "$mid"
  if [ "$VERDICT" = closes ]; then pass="$mid"; else fail="$mid"; fi
done

#---- answer: tightest closing period whose looser points all closed ---------------------------
read -r limit below nonmono < <(printf '%s' "$POINTS" | sort -k1,1gr | awk '
  !broken && $2=="closes" {limit=$1; next}
  !broken && $2=="fails"  {broken=1; below=$1; next}
  broken && $2=="closes"  {nonmono="yes"}
  END {print (limit==""?"none":limit), (below==""?"none":below), (nonmono==""?"no":nonmono)}')
[ "$limit" != none ] || { echo "sweep.sh: the loosest point failed; no limit" >&2; exit 1; }
{
  echo "design $design"
  echo "phase $phase"
  echo "limit_ns $limit"
  echo "first_fail_below_ns $below"
  echo "fmax_mhz $(awk -v p="$limit" 'BEGIN{printf "%.1f", 1000/p}')"
  echo "nonmonotone $nonmono"
  echo "commit $COMMIT"
  [ "$phase" = syn ] && echo "note synthesis-only estimate (steers phase pnr; not an Fmax result)"
} > "$RES"
echo "sweep.sh: $design $phase limit $limit ns (next failing point $below ns, nonmonotone $nonmono) -> $RES"
