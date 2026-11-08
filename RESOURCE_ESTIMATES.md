# Resource estimates

Numbers below are unverified estimates attributed to Yosys 0.x generic
synthesis (`make synth_report`); they have not been independently
reproduced. They are pre-place-and-route. See `SYNTH_REPORT.md` for the most recent
run; this document explains what dominates the area and how to shrink
it.

## Summary (post-Yosys, pre-PnR)

| Target                         | Comment |
|--------------------------------|---------|
| Lattice iCE40 UP5K             | LUT-heavy: the 16x AES S-box LUTs and the round combinational network dominate. The GF(2^128) alpha multiplier is expected to cost ~25 LUT4 (unverified estimate). Fit on the UP5K (5280 logic tiles) has not been confirmed. |
| Lattice ECP5 LFE5UM-25         | LUT4 dominates. ECP5 generic synthesis in Yosys 0.x does not auto-pack the AES round into `MULT18X18`; nextpnr-ecp5 packs tighter; vendor (Diamond) tighter still. |
| Xilinx Artix-7 XC7A35T         | Yosys-generic synthesis here counts LUT6 + CARRY4. Vivado synth_design will pack the AES S-box into BRAM18 if instructed and the LUT count drops sharply. |
| Cyclone V 5CSEMA5F31C6         | Quartus folds the AES S-box into M10K block RAMs; ALM count is much lower than the Yosys soft estimate. |
| Gowin GW1NR-9 (Tang Nano 9K)   | Not characterised here. Uses BRAM-backed S-box mapping; size comparable to ECP5 with vendor flow. |

For exact LUT/FF/BRAM numbers run `make synth_report` and read
`SYNTH_REPORT.md`. There is no CI; the committed synthesis-comparison
report is not CI output.

## What dominates the area

- **AES-128 cipher core (forward + inverse)**: 16x S-box (forward) + 16x
  inverse S-box for the decrypt path, plus the MixColumns and
  InvMixColumns combinational networks. This is the single largest
  contributor and it is the same code path that the sibling
  `aes128-fpga-core` ships; the per-block cycle count here is identical.
- **AES key expansion**: 11 round keys x 128 bits = 1408 FFs of state
  for the round-key schedule.
- **Tweak register and GF(2^128) alpha multiplier**: 128 FFs for `tweak_q`
  plus a flat combinational shift+reduce network expected to cost ~25
  LUT4 on iCE40 / ~10 LUT6 on Artix-7 (unverified estimates). Dwarfed by
  the AES cipher.
- **FSM and session registers**: 128b k1 + 128b k2 + 128b sector + 128b
  cts_held + 128b cts_t_prev + 16b total + 12b block_idx + ~30b FSM ~
  830 FFs.

XTS-AES is therefore expected to be approximately **the same area as a
stand-alone AES-128 cipher core** (one cipher engine is shared between
tweak derivation and data rounds). A two-engine variant that runs
T-derivation in parallel with the first data block would cost ~1.8x the
area but cut ~12 cycles off the per-sector latency (unverified
estimates); it is on the roadmap together with an AES-XTS-256 variant.
Neither is implemented.

## What you can do to shrink it

- **BRAM-mapped S-box**: replace the combinational `aes_sbox` with a
  256x8 ROM. Vivado / Quartus / Diamond do this automatically when the
  S-box is structured as a function of a single 8-bit input; the
  Yosys-generic flow does not. A `(* rom_style = "block" *)` attribute
  on the case statement is expected to reclaim roughly 40-50% of the LUT
  cost on Artix-7 and ECP5 (unverified estimate). Not included in this
  repository.
- **Encrypt-only build**: drop `aes_inv_sbox` and the decrypt-side
  InvShiftRows / InvMixColumns network if the deployment only writes
  encrypted sectors and reads them via a separate decrypt pipeline.
  Not included in this repository (there is no `XTS_ENCRYPT_ONLY`
  define).
- **Single-S-box AES (8-bit datapath)**: serialise the 16 S-box
  invocations onto a single shared S-box, trading lower AES area for
  higher latency per block. Reasonable for very small iCE40 boards. Not
  included in this repository.

## What you can do to push throughput

None of the options below is included in this repository; the figures
are unverified estimates.

- **Pipelined AES** (not implemented): unroll the 10-round loop into a
  10-stage pipeline. Steady-state throughput would become 1 keystream
  block per cycle instead of every 12 cycles, at ~10x area for the AES
  engine.
- **Two-engine XTS top** (not implemented): run T-derivation in parallel
  with the first data block. Would cut ~12 cycles off the per-sector
  latency at ~1.8x the area.
- **AES-XTS-256** (not implemented): same FSM with an AES-256 cipher
  core swapped in. Uses two 256-bit keys (512-bit XTS key). Area would
  be ~1.4x AES-XTS-128 because key expansion is more expensive but the round
  count is also higher (14 vs 10).

## Frequency

The figures below are unverified estimates; no place-and-route timing has
been confirmed.

- iCE40 UP5K, default toolchain (Yosys + nextpnr), no constraints:
  limited by the AES S-box LUT depth (~30-40 MHz on generic synth).
- ECP5: ~80-100 MHz on generic synth.
- Artix-7 -1 speed grade: ~100 MHz typical with Yosys, easily 200+ MHz
  with Vivado + S-box BRAM mapping.
- Cyclone V: similar to Artix-7 with M10K-backed S-boxes.

The throughput is gated by the AES cipher (1 block per 12 cycles on
the iterative core). For a 4-KB sector the encryptor finishes in
roughly 13 + 32*13 = 429 cycles, i.e. ~4.3 microseconds at 100 MHz.
Sustained: ~95 MB/s per core (unverified estimate). No pipelined variant
is included in this repository.

## Power

Power has not been characterized. The AES round update toggles ~1500 FFs every 12 cycles; the
tweak register toggles once per data block. Static power is dominated
by the FPGA itself.

## How to reproduce

```bash
make synth_report
```

This runs Yosys with `synth_ice40`, `synth_ecp5` (with `-abc9`), and
`synth_xilinx`, then `stat`, and writes the result to
`SYNTH_REPORT.md`. Vendor flows (Vivado, Quartus) are detected
automatically when on PATH.

For end-to-end place-and-route numbers (post-PnR LUT counts and timing),
run the vendor flow:
- iCE40 / ECP5: `nextpnr-ice40` / `nextpnr-ecp5` with Yosys output.
- Xilinx: Vivado with a project pointing at the `rtl/` files.
- Lattice Diamond / Radiant: project with `rtl/` added.
- Quartus: project with `rtl/` added.
