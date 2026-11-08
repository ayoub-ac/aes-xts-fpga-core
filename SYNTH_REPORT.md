# Synthesis comparison report

Unverified: this file is not CI output and its numbers have not been
independently reproduced. Regenerate it locally with `make synth_report`.
Numbers are post-synthesis, pre-place-and-route.
Vendor flows (Vivado / Quartus) usually pack tighter than the open-source flow,
so the Yosys numbers should be read as upper bounds.

| Toolchain                | Target                  | Result                       |
|--------------------------|-------------------------|------------------------------|
| Yosys 0.x synth_ice40    | iCE40 UP5K              | 8397 LUT / 2754 FF / 32 BRAM              |
| Yosys 0.x synth_ecp5     | ECP5 LFE5UM-25          | 19545 LUT / 3010 FF / 0 BRAM               |
| Yosys 0.x synth_xilinx   | Xilinx 7-series         | 10428 LUT / 5508 FF / 0 BRAM                |
| Vivado synth_design      | Artix-7 xc7a35tcsg324-1 | (skipped: vivado not on PATH)             |
| Quartus Pro              | Cyclone V 5CSEMA5F31C6  | (skipped: quartus_sh not on PATH)            |

## Notes

* The dominant area is the AES-128 cipher core (forward + inverse
  S-boxes, MixColumns and InvMixColumns combinational networks).
  AES-XTS shares one cipher engine across the tweak-derivation pass
  (`AES_enc(k2, sector)`) and the per-block data passes
  (`AES_{enc|dec}(k1, ...)`); area is therefore close to one
  AES-128 core plus a small GF(2^128) alpha multiplier and the FSM.
* The GF(2^128) alpha multiplier (`rtl/gf128_mul_alpha.sv`) is a flat
  combinational byte-shift with a single 8-bit reduction XOR; it is
  expected to cost only a handful of LUTs (~25 LUT4 on iCE40, unverified
  estimate) and zero registers - the
  tweak register lives in `aes_xts_top.sv`.
* AES-XTS is expected to be roughly the same area as a stand-alone
  AES-128 cipher (one cipher core is shared between tweak derivation
  and data rounds). A "two-engine" variant that runs T-derivation in
  parallel with the first data block would cost ~1.8x the area but cut
  ~12 cycles off the per-sector latency (unverified estimates); it is
  on the roadmap together with an AES-XTS-256 variant. Neither is
  implemented.
* Vivado / Quartus rows are skipped automatically when those tools are
  not on PATH; on a CI runner with WebPACK / Web Edition installed they
  will be populated from a real synth_design / quartus_sh run.

## Reproduction

```
make synth_report
```

Raw logs land in `synth_report/`.
