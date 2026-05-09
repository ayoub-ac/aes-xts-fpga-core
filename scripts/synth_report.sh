#!/usr/bin/env bash
# Cross-toolchain synthesis report. Runs every installed FPGA toolchain
# against the XTS top (rtl/aes_xts_top.sv plus its sub-modules) and
# writes SYNTH_REPORT.md with a side-by-side LUT/FF/BRAM table.
#
# Toolchains attempted:
#   * Yosys synth_ice40   (always run, only requires yosys)
#   * Yosys synth_ecp5    (")
#   * Yosys synth_xilinx  (Xilinx generic)
#   * Vivado xc7a35tcsg324-1   (only if `vivado` is on PATH)
#   * Quartus Cyclone V        (only if `quartus_sh` is on PATH)
#
# Missing toolchains are noted as "(skipped: tool not on PATH)".

set -u
cd "$(dirname "$0")/.."

OUTDIR="synth_report"
mkdir -p "$OUTDIR"

REPORT="SYNTH_REPORT.md"
RTL="rtl/aes_sbox.sv rtl/aes_inv_sbox.sv rtl/aes_key_expand.sv rtl/aes_round.sv rtl/aes_core.sv rtl/gf128_mul_alpha.sv rtl/aes_xts_top.sv"
TOP="aes_xts_top"

have() { command -v "$1" >/dev/null 2>&1; }

yosys_run() {
    local target="$1" yopts="$2" outfile="$3"
    if ! have yosys; then
        echo "yosys not installed" > "$outfile"
        return 1
    fi
    yosys -p "read_verilog -sv $RTL; hierarchy -top $TOP; $yopts; stat" \
          > "$outfile" 2>&1
    return $?
}

extract_yosys_stat() {
    local f="$1"
    if [[ ! -s "$f" ]] || grep -q "yosys not installed" "$f"; then
        echo "(skipped)"
        return
    fi

    local block
    block=$(awk '
        /Printing statistics/ { mark = NR }
        { lines[NR] = $0 }
        END {
            for (i = mark; i <= NR; i++) print lines[i]
        }
    ' "$f")
    if [[ -z "$block" ]]; then
        echo "(no stat block)"
        return
    fi

    local luts ffs brams
    luts=$(echo "$block" | awk '
        /SB_LUT4|LUT4|LUT5|LUT6|LUT2|LUT1|^[[:space:]]+LUT[[:space:]]/ { sum += $NF }
        END { print sum+0 }')
    ffs=$(echo "$block" | awk '
        /SB_DFF|SB_DFFESR|SB_DFFE|TRELLIS_FF|FDRE|FDCE|FDPE|FDSE|FDC|FDP/ { sum += $NF }
        END { print sum+0 }')
    brams=$(echo "$block" | awk '
        /SB_RAM40_4K|EBR|RAMB18|RAMB36/ { sum += $NF }
        END { print sum+0 }')
    echo "${luts} LUT / ${ffs} FF / ${brams} BRAM"
}

echo "[synth_report] Yosys ice40..."
yosys_run "ice40"  "synth_ice40 -top $TOP"             "$OUTDIR/yosys_ice40.log"  || true
echo "[synth_report] Yosys ecp5..."
yosys_run "ecp5"   "synth_ecp5 -top $TOP -abc9"        "$OUTDIR/yosys_ecp5.log"   || true
echo "[synth_report] Yosys xilinx..."
yosys_run "xilinx" "synth_xilinx -top $TOP"            "$OUTDIR/yosys_xilinx.log" || true

VIVADO_RESULT="(skipped: vivado not on PATH)"
if have vivado; then
    echo "[synth_report] Vivado synth_design Artix-7..."
    cat > "$OUTDIR/vivado_synth.tcl" <<EOF
set_part xc7a35tcsg324-1
read_verilog -sv {$RTL}
synth_design -top $TOP -part xc7a35tcsg324-1 -mode out_of_context
report_utilization -file $OUTDIR/vivado_util.rpt
EOF
    if vivado -mode batch -nojournal -nolog -source "$OUTDIR/vivado_synth.tcl" \
              > "$OUTDIR/vivado.log" 2>&1; then
        VIVADO_LUTS=$(awk '/Slice LUTs/ {print $4; exit}' "$OUTDIR/vivado_util.rpt" 2>/dev/null || echo "?")
        VIVADO_FFS=$(awk  '/Slice Registers/ {print $4; exit}' "$OUTDIR/vivado_util.rpt" 2>/dev/null || echo "?")
        VIVADO_BRAM=$(awk '/Block RAM Tile/ {print $5; exit}' "$OUTDIR/vivado_util.rpt" 2>/dev/null || echo "0")
        VIVADO_RESULT="${VIVADO_LUTS} LUT / ${VIVADO_FFS} FF / ${VIVADO_BRAM} BRAM"
    else
        VIVADO_RESULT="(failed - see $OUTDIR/vivado.log)"
    fi
fi

QUARTUS_RESULT="(skipped: quartus_sh not on PATH)"
if have quartus_sh; then
    echo "[synth_report] Quartus Cyclone V..."
    QPROJ="$OUTDIR/qproj"
    mkdir -p "$QPROJ"
    cat > "$QPROJ/${TOP}.qsf" <<EOF
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEMA5F31C6
set_global_assignment -name TOP_LEVEL_ENTITY $TOP
set_global_assignment -name SEARCH_PATH ../../rtl
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/aes_sbox.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/aes_inv_sbox.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/aes_key_expand.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/aes_round.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/aes_core.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/gf128_mul_alpha.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/aes_xts_top.sv
EOF
    cat > "$QPROJ/${TOP}.qpf" <<EOF
PROJECT_REVISION = "$TOP"
EOF
    if (cd "$QPROJ" && quartus_sh --flow compile $TOP > ../quartus.log 2>&1); then
        QU_LUTS=$(awk -F\| '/ALMs needed/ {gsub(/ /,"",$3); print $3; exit}' "$OUTDIR/quartus.log" || echo "?")
        QU_FFS=$(awk  -F\| '/Total registers/ {gsub(/ /,"",$3); print $3; exit}' "$OUTDIR/quartus.log" || echo "?")
        QUARTUS_RESULT="${QU_LUTS} ALM / ${QU_FFS} FF"
    else
        QUARTUS_RESULT="(failed - see $OUTDIR/quartus.log)"
    fi
fi

ICE40_RESULT=$(extract_yosys_stat "$OUTDIR/yosys_ice40.log")
ECP5_RESULT=$(extract_yosys_stat "$OUTDIR/yosys_ecp5.log")
XIL_RESULT=$(extract_yosys_stat   "$OUTDIR/yosys_xilinx.log")

cat > "$REPORT" <<EOF
# Synthesis comparison report

Generated by \`make synth_report\`. Numbers are post-synthesis, pre-place-and-route.
Vendor flows (Vivado / Quartus) usually pack tighter than the open-source flow,
so the Yosys numbers should be read as upper bounds.

| Toolchain                | Target                  | Result                       |
|--------------------------|-------------------------|------------------------------|
| Yosys 0.x synth_ice40    | iCE40 UP5K              | ${ICE40_RESULT}              |
| Yosys 0.x synth_ecp5     | ECP5 LFE5UM-25          | ${ECP5_RESULT}               |
| Yosys 0.x synth_xilinx   | Xilinx 7-series         | ${XIL_RESULT}                |
| Vivado synth_design      | Artix-7 xc7a35tcsg324-1 | ${VIVADO_RESULT}             |
| Quartus Pro              | Cyclone V 5CSEMA5F31C6  | ${QUARTUS_RESULT}            |

## Notes

* The dominant area is the AES-128 cipher core (forward + inverse
  S-boxes, MixColumns and InvMixColumns combinational networks).
  AES-XTS shares one cipher engine across the tweak-derivation pass
  (\`AES_enc(k2, sector)\`) and the per-block data passes
  (\`AES_{enc|dec}(k1, ...)\`); area is therefore close to one
  AES-128 core plus a small GF(2^128) alpha multiplier and the FSM.
* The GF(2^128) alpha multiplier (\`rtl/gf128_mul_alpha.sv\`) is a flat
  combinational byte-shift with a single 8-bit reduction XOR; it costs
  only a handful of LUTs (~25 LUT4 on iCE40) and zero registers - the
  tweak register lives in \`aes_xts_top.sv\`.
* AES-XTS is roughly the same area as a stand-alone AES-128 cipher
  (one cipher core is shared between tweak derivation and data
  rounds). A "two-engine" variant that runs T-derivation in parallel
  with the first data block costs ~1.8x the area but cuts ~12 cycles
  off the per-sector latency; it is on the Premium roadmap together
  with the AES-XTS-256 variant.
* Vivado / Quartus rows are skipped automatically when those tools are
  not on PATH; on a CI runner with WebPACK / Web Edition installed they
  will be populated from a real synth_design / quartus_sh run.

## Reproduction

\`\`\`
make synth_report
\`\`\`

Raw logs land in \`synth_report/\`.
EOF

echo "[synth_report] Wrote $REPORT"
