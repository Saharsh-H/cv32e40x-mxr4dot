#!/usr/bin/env bash
# Check rtl/mxdotp/ for signals used before their declaration (run before any synthesis
# run). Builds one Verilator XML of mxdotp_core_top with the same sources and include
# paths as the make full build, then runs both scans (fwdref_xml.py, fwdref_text.py).
#
#   tb/scripts/fwdref_check.sh [repo_root]   (default: this repo; writes into a temp dir)
#
# Exit status: 0 both scans find nothing, 1 a scan found forward references,
# 2 the XML could not be built.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "${1:-$TB/..}" && pwd)"
TB="$ROOT/tb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Core files: the same filter as the $(VERILATOR_FLIST) rule in tb/Makefile.
sed "s|\${DESIGN_RTL_DIR}|$ROOT/rtl|g" "$ROOT/cv32e40x_manifest.flist" | \
    grep -v "cv32e40x_wrapper.sv" | grep -v "cv32e40x_rvfi.sv" | \
    grep -v "cv32e40x_rvfi_pkg.sv" | grep -v "/sva/" > "$TMP/core.f"
# Coprocessor files: MXDOTP_SRCS from tb/Makefile itself, so a new file is picked up.
MXDOTP_SRCS="$(make -s -C "$TB" --no-print-directory --eval='print-%: ; @echo $($*)' print-MXDOTP_SRCS)"
MXDOTP_SRCS="$(for f in $MXDOTP_SRCS; do (cd "$TB" && realpath "$f"); done)"

if ! (cd "$TMP" && verilator --xml-only --xml-output "$TMP/top.xml" -Wno-fatal -Wno-lint -Wno-style \
        --top-module mxdotp_core_top -I"$ROOT/rtl/include" -I"$ROOT/rtl/mxdotp" -I"$ROOT/bhv" \
        -I"$ROOT/bhv/include" -f "$TMP/core.f" $MXDOTP_SRCS > "$TMP/verilator.log" 2>&1); then
    cat "$TMP/verilator.log" >&2
    echo "fwdref_check: verilator --xml-only failed" >&2
    exit 2
fi

status=0
python3 "$HERE/fwdref_xml.py" "$TMP/top.xml" || status=1
python3 "$HERE/fwdref_text.py" "$TMP/top.xml" || status=1
[ $status -eq 0 ] && echo "fwdref_check: PASS (0 forward references in rtl/mxdotp/)" \
                  || echo "fwdref_check: FAIL"
exit $status
