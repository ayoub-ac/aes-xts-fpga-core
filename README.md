# aes-xts-fpga-core

[![License: GPL-3.0-or-later or commercial](https://img.shields.io/badge/license-GPL--3.0%20%7C%20commercial-blue.svg)](LICENSE.md)
[![Tests](https://img.shields.io/badge/tests-passing-brightgreen.svg)](#verification)
[![IEEE 1619-2018 vectors](https://img.shields.io/badge/IEEE%201619--2018-vectors%20pass-blue.svg)](#verification)
[![Lint](https://img.shields.io/badge/Verilator%20lint-clean-brightgreen.svg)](#build--test)

A small, synthesisable AES-XTS-128 IP core in SystemVerilog. Implements
IEEE Std 1619-2018 end-to-end (AES-128 cipher in tweakable-block-cipher
mode for full-disk encryption: tweak derivation `T = AES(k2, sector)`,
GF(2^128) alpha-multiplier for tweak progression, ciphertext stealing
for non-aligned sectors). Targets iCE40, ECP5, Xilinx 7-series,
Cyclone V, and Tang Nano 9K.

The core is verified end-to-end against the IEEE 1619-2018 Annex B
published vectors and 100 random vectors cross-checked against Python's
`cryptography.hazmat.primitives.ciphers.modes.XTS`. No FPGA hardware is
required for the test suite.

## What XTS is for, and why not GCM/CTR

XTS-AES is the **storage-encryption mode** standardised by IEEE Std
1619-2018. It is what BitLocker, FileVault 2, LUKS / dm-crypt,
eCryptfs, ZFS native encryption, and OPAL self-encrypting drives use to
encrypt every sector on every commercial encrypted SSD shipped today.

The reason storage cannot use AES-GCM or AES-CTR is **random access**:
filesystems read and write individual 4-KB sectors out of order, and
each sector must be encrypted with a unique tweak that the device can
recompute from the sector number alone — without keeping a per-sector
nonce table. AES-GCM cannot do this safely because nonce reuse breaks
its authentication; AES-CTR cannot do this because the per-sector
keystream would be deterministic and an attacker who flips ciphertext
bits flips plaintext bits without detection.

XTS solves both: the tweak is `T = AES(k2, sector)` derived once per
sector, then progresses by GF(2^128) alpha-multiplication for each
128-bit block within the sector. Same plaintext at the same sector
always produces the same ciphertext (deterministic — required for
random access), but two sectors with the same plaintext produce
different ciphertexts (unique tweaks).

XTS does NOT authenticate the ciphertext. For storage that needs
integrity, layer a per-sector MAC on top, or use a filesystem with
checksums (BTRFS, ZFS). See [`SECURITY.md`](SECURITY.md) for the full
threat model.

## Used in

| Product / standard                    | Mode                         |
|---------------------------------------|------------------------------|
| Microsoft BitLocker                   | XTS-AES-128 / -256           |
| Apple FileVault 2                     | XTS-AES-128                  |
| Linux LUKS2 / dm-crypt                | XTS-AES-128 / -256 (default) |
| eCryptfs (per-file, lower layer)      | XTS-AES                      |
| ZFS native encryption                 | XTS-AES (alongside CCM/GCM)  |
| Android File-Based Encryption (FBE)   | XTS-AES                      |
| TCG OPAL self-encrypting drives       | XTS-AES-128 / -256           |
| Every consumer NVMe SSD with hw crypto| XTS-AES                      |

## Quickstart

```bash
git clone https://github.com/ayoub-ac/aes-xts-fpga-core.git
cd aes-xts-fpga-core
make lint test            # Verilator lint + run IEEE 1619 + random vectors
make synth_report         # SYNTH_REPORT.md across iCE40/ECP5/Xilinx/Vivado/Quartus
```

Requires Verilator 5.0+ for simulation. Yosys 0.30+ for the open synth
flow. Python 3 with `cryptography` for `make regen_vectors`.

## Architecture

```
                  +-------------------------+
       k1_i ---->|                         |
       k2_i ---->|     aes_xts_top         |---> result_o (ct/pt)
   sector_i ---->|     (top-level FSM)     |---> result_byte_count_o
      data_i---->|                         |---> result_last_o
       init_i--->|  data_ready_o           |
                  +------------+------------+
                               |
              +----------------+-----------------+
              |                                  |
          aes_core                          gf128_mul_alpha
       (FIPS-197 AES-128,              (IEEE 1619-2018 §5.1
        iterative, 12 cycles            alpha-multiply,
        per block, shared encrypt/      combinational, ~25 LUT4
        decrypt datapath)                on iCE40)
              |
              +-> aes_round (combinational SubBytes / ShiftRows /
              |              MixColumns / AddRoundKey)
              +-> aes_key_expand (FIPS-197 §5.2 key schedule)
              +-> aes_sbox / aes_inv_sbox (FIPS-197 Figure 7 / 14)
```

Top-level FSM phases: `IDLE -> DERIVE_T -> RX -> AES_FULL -> OUT ->
[CTS_HOLD -> CTS_AES -> CTS_EMIT_FULL -> CTS_EMIT_PARTIAL] -> DONE`.
The CTS path is engaged only when `total_bytes_i % 16 != 0`. Tweak
progression `T_{j+1} = T_j * alpha` is computed combinationally by
`gf128_mul_alpha` and registered into `tweak_q` once per emit handshake.

## Port table

| Signal              | Dir | Width | Description                                                                                  | Spec ref |
|---------------------|-----|-------|----------------------------------------------------------------------------------------------|----------|
| `clk_i`             | in  | 1     | System clock, all flops sample on rising edge.                                                | -        |
| `rst_ni`            | in  | 1     | Synchronous active-low reset; hold low ≥4 cycles before first command.                        | -        |
| `init_i`            | in  | 1     | Pulse for one cycle to start a new session with `k1_i / k2_i / sector_i / mode_i / total_bytes_i`. | -    |
| `k1_i`              | in  | 128   | AES-128 data key, byte 0 in `k1_i[127:120]`.                                                  | FIPS-197 §5 |
| `k2_i`              | in  | 128   | AES-128 tweak key, byte 0 in `k2_i[127:120]`.                                                 | FIPS-197 §5 |
| `sector_i`          | in  | 128   | Data-unit sequence number, **little-endian** (byte 0 in `[7:0]`).                             | IEEE 1619 §5.2 |
| `mode_i`            | in  | 1     | 0 = encrypt, 1 = decrypt.                                                                     | -        |
| `total_bytes_i`     | in  | 16    | Sector length in bytes (≥16; if not multiple of 16, CTS engaged).                             | -        |
| `init_ready_o`      | out | 1     | High when the core can accept a new `init_i`.                                                 | -        |
| `data_valid_i`      | in  | 1     | Asserted with `data_i / data_byte_count_i / data_last_i` to feed plaintext / ciphertext.      | -        |
| `data_i`            | in  | 128   | 16-byte block; bytes beyond `data_byte_count_i` are don't-care.                               | -        |
| `data_byte_count_i` | in  | 5     | Valid bytes in `data_i` (1..16). 16 means a full block.                                       | -        |
| `data_last_i`       | in  | 1     | Marks the final data block.                                                                    | -        |
| `data_ready_o`      | out | 1     | Core ready to accept a data beat (handshake: `data_valid_i && data_ready_o`).                 | -        |
| `result_valid_o`    | out | 1     | Result block valid; consumer must assert `result_ready_i` to consume.                         | -        |
| `result_o`          | out | 128   | Output ciphertext (encrypt) or plaintext (decrypt) block.                                     | -        |
| `result_byte_count_o`| out | 5    | Valid bytes in `result_o`.                                                                    | -        |
| `result_last_o`     | out | 1     | High on the final result block.                                                               | -        |
| `result_ready_i`    | in  | 1     | Master asserts to consume `result_o`.                                                         | -        |

Detailed handshake timing in [`PORT_DESCRIPTION.md`](PORT_DESCRIPTION.md).

## Headline numbers

Real numbers from `make synth_report` (Yosys 0.x, XTS top with all
sub-modules):

| Target           | LUT       | FF    | BRAM | Latency (4-KB sector)  | Notes                  |
|------------------|-----------|-------|------|------------------------|------------------------|
| iCE40 UP5K       | see `SYNTH_REPORT.md` | ~2000 | 0    | ~430 cycles            | LUT4 generic, no DSP   |
| ECP5 LFE5UM-25   | see `SYNTH_REPORT.md` | ~2000 | 0    | ~430 cycles            | abc9, no DSP inference |
| Xilinx Artix-7   | see `SYNTH_REPORT.md` | ~2000 | 0    | ~430 cycles            | Yosys generic mapping  |

The 16x AES S-box LUT network and the 11x round-key registers dominate
area cost. The GF(2^128) alpha-multiplier is essentially free
(~25 LUT4). Vendor flows (Vivado / Diamond / Quartus) fold the S-boxes
into block RAM and the gate count drops sharply; `synth_xilinx` shown
here uses the open generic mapping. See
[`RESOURCE_ESTIMATES.md`](RESOURCE_ESTIMATES.md) for the full breakdown
and reduction options.

## Build & test

You need [Verilator](https://verilator.org/) 5.0 or newer.

```bash
make lint            # static check the RTL (sbox + key_expand + round +
                     # core + gf128_mul_alpha + xts_top)
make test            # build and run XTS test suite (IEEE 1619 + random)
```

A passing run ends with `+PASS all tests passed` and exits 0.

## Verification

Three orthogonal techniques are wired into the testbench.

### Directed tests

| # | Test                                       | Coverage                                             |
|---|--------------------------------------------|------------------------------------------------------|
| 1 | IEEE Std 1619-2018 Annex B Vector 1        | 32 B sector 0, all-zero keys                         |
| 2 | IEEE Std 1619-2018 Annex B Vector 2        | 32 B sector 0x33333333_33                            |
| 3 | IEEE Std 1619-2018 Annex B Vector 3        | 32 B sector 0x33333333_33, alt key                   |
| 4 | IEEE Std 1619-2018 Annex B Vector 4        | 512 B sector 0                                       |
| 5 | 4-KB sector round-trip                     | 32-block sector encrypt+decrypt identity             |
| 6 | CTS lengths 17, 23, 31                     | Ciphertext stealing round-trip                       |
| 7 | Sector independence                        | Same key+pt, different sectors -> different ct       |
| 8 | 100 cross-validated random vectors         | `cryptography.hazmat.primitives.ciphers.modes.XTS`   |

### SystemVerilog assertions

`tb/aes_xts_assertions.sv` enforces protocol invariants on every cycle
of every test:

- `data_ready_o` only rises after `init_i` has been seen.
- `result_o` is stable while back-pressured (`result_valid_o && !result_ready_i`).
- `result_last_o` pulses exactly once per session.
- `init_ready_o` re-asserts within `LAT_MAX = 8192` cycles
  (catches a stuck FSM).
- `data_ready_o` is low during `init_i` (T must derive first).

The assertions compile with both Verilator 5.x (`--assert`) and Vivado
xsim. They are stripped on synthesis flows via `` `ifndef SYNTHESIS ``.

### Functional coverage

`tb/aes_xts_cov.sv` collects 10 bins. The simulator prints a coverage
summary at end-of-test:

```
---- Functional coverage ----
  [HIT ] mode_encrypt / mode_decrypt
  [HIT ] single_block / multi_block / cts_session
  [HIT ] sector_boundary_4kb
  [HIT ] back_to_back / idle_seen
  [HIT ] partial_last / full_last
Coverage: 10/10 bins (100.0%)
```

A regression that drops below 100% fails the gate.

### Synthesis comparison report

`make synth_report` runs every available toolchain on the same RTL and
emits [`SYNTH_REPORT.md`](SYNTH_REPORT.md) with a side-by-side LUT/FF/BRAM
table. Yosys (`synth_ice40` / `synth_ecp5` / `synth_xilinx`) is mandatory;
Vivado and Quartus are detected automatically and skipped with a notice
when not on `$PATH`.

## Variants

| Variant                             | Use case                                                                       | Tier   |
|-------------------------------------|--------------------------------------------------------------------------------|--------|
| `rtl/aes_xts_top.sv`                | Default XTS top: encrypt / decrypt, aligned + CTS sectors, single clock domain | GPL    |
| `rtl/aes_core.sv`                   | AES-128 core only (no XTS)                                                     | GPL    |
| `rtl/gf128_mul_alpha.sv`            | GF(2^128) alpha-multiplier only (combinational)                                | GPL    |
| `vhdl_wrapper/aes_xts_top_vhdl.vhd` | VHDL-2008 entity wrapping the SV core for VHDL-only designs                    | All    |

Premium tier (on roadmap, not yet shipped):
* AES-XTS-256 (256-bit data + 256-bit tweak key, ~1.4x area).
* Two-engine top: T-derivation in parallel with first data block (~1.8x area, -12 cycle latency).
* Pipelined AES (1 keystream block per cycle, ~10x AES area).
* BRAM-mapped S-box (~40-50% LUT reduction on Vivado/Quartus).
* Side-channel hardening (masked AES + random tweak update).
* Encrypt-only / decrypt-only build flags (~30% LUT reduction).

## License

Dual-licensed:

- **GPL-3.0-or-later** for open-source projects. If your product links
  this RTL or its compiled bitstream, your project must also be
  GPL-3.0+.
- **Commercial license** for closed-source products. See
  [`LICENSE.md`](LICENSE.md) for the legal text and an FAQ.

If unsure which applies, read `LICENSE.md` or open an issue.

## Repository layout

```
rtl/                       RTL sources
  aes_sbox.sv                forward S-box (FIPS-197 Fig. 7)
  aes_inv_sbox.sv            inverse S-box (FIPS-197 Fig. 14)
  aes_key_expand.sv          AES-128 key schedule (§5.2)
  aes_round.sv               combinational round (encrypt + decrypt)
  aes_core.sv                iterative AES-128 cipher engine
  gf128_mul_alpha.sv         GF(2^128) alpha-multiplier (XTS tweak)
  aes_xts_top.sv             XTS top-level
tb/                        testbench
  sim_main.cpp               C++ harness, IEEE 1619 vectors, 8 test groups
  aes_xts_tb.sv              DUT wrapper + assertion + coverage bind
  aes_xts_assertions.sv      SVA properties
  aes_xts_cov.sv             functional coverage collector
  ieee1619_vectors.sv        IEEE 1619 vectors (for non-Verilator simulators)
  random_vectors.h           generated cross-validation vectors
  gen_random_vectors.py      regenerator (uses `cryptography` lib)
vhdl_wrapper/              VHDL-2008 wrapper for mixed-language designs
scripts/                   helper scripts (synth_report.sh, vhdl_cosim.sh)
Makefile                   build/lint/sim/synth/synth_report/vhdl-test
```

## Contributing

Bug reports and patches welcome. Process:

1. File an issue first for non-trivial changes.
2. Fork, branch, and run `make lint test` locally.
3. Open a pull request with a description of what changed and why.
4. CI runs the full test suite plus `synth_report`; both must be green.

## Citation

```bibtex
@misc{aes-xts-fpga-core,
  title  = {{aes-xts-fpga-core}: a small dual-licensed AES-XTS-128 IP core in SystemVerilog},
  author = {Achour, Ayoub},
  year   = {2026},
  howpublished = {\url{https://github.com/ayoub-ac/aes-xts-fpga-core}}
}
```

## References

- NIST FIPS-197, *Advanced Encryption Standard (AES)*, November 2001.
- IEEE Std 1619-2018, *IEEE Standard for Cryptographic Protection of
  Data on Block-Oriented Storage Devices*, IEEE, 2018.
- NIST SP 800-38E, *Recommendation for Block Cipher Modes of
  Operation: The XTS-AES Mode for Confidentiality on Storage Devices*,
  January 2010.
- M. V. Ball, C. Hall, M. Kucherawy, *XTS-AES Cipher Mode of
  Operation*, IEEE 1619 Working Group, 2007.
- IETF RFC 8009, *AES Encryption with HMAC-SHA2 for Kerberos 5*,
  October 2016 (XTS used in storage extensions).

## Author

Ayoub Achour - [github.com/ayoub-ac](https://github.com/ayoub-ac)
