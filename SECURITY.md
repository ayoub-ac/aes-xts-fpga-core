# Security model

This document describes what `aes_xts_top` is designed to defend against,
what it is NOT designed to defend against, and how to evaluate the
claims.

If you need a side-channel-resistant XTS core for a commercial storage
device, read this whole document and decide whether the threat model
matches your deployment. Don't trust marketing copy; trust the threat
model and your own evaluation.

## XTS is for STORAGE, not generic AEAD — read this first

XTS-AES (IEEE Std 1619-2018) is the dominant tweakable-block-cipher mode
for **full-disk encryption**: BitLocker, FileVault 2, LUKS / dm-crypt,
and the OPAL self-encrypting-drive class use it. It is **not** an AEAD.

Specifically, XTS-AES does NOT provide:

1. **Authentication / integrity.** An attacker who can flip ciphertext
   bits will produce flipped plaintext bits on decrypt; the storage
   layer cannot detect the tampering. Real FDE deployments rely on
   filesystem-layer integrity (BTRFS, ZFS) or per-sector MACs in a
   higher layer to catch tampering.
2. **Sector-swap protection.** An attacker who can swap two ciphertext
   sectors swaps the plaintext sectors. XTS uses the sector number as
   the tweak, so swapping a sector reads back garbage at the wrong
   tweak — but if the attacker swaps the *content* of sector A with
   the *content* of sector B before encryption, both decrypt cleanly.
3. **Replay protection.** An attacker who snapshots an old version of
   a sector and writes it back later will read back the old plaintext.

**If you need authenticated encryption for storage**, layer XTS underneath
a per-sector MAC (HMAC-SHA-256 + monotonic counter) or use AES-GCM-SIV
(RFC 8452) at the application layer. See the sibling
[aes-gcm-fpga-core](https://github.com/ayoub-ac/aes-gcm-fpga-core)
project for the AEAD path.

## What is protected

### 1. Confidentiality of stored sectors

When the (k1, k2) pair is unique to the storage device and the sector
number is unique per data unit, an attacker without the keys cannot
recover the plaintext of a sector — and crucially, two encryptions of
the same plaintext at the *same* sector number under the *same* keys
produce the SAME ciphertext (deterministic encryption is required for
random-access storage; the per-sector tweak is what makes it safe
against the obvious GCM-style nonce-reuse failure).

### 2. Constant-time execution (intended; not evaluated)

AES (FIPS-197) is implementable without data-dependent branches. The
FSM in `aes_xts_top` is intended to be constant-time; not evaluated. Its
cycle count is designed to depend only on the `total_bytes_i` value and
CTS-vs-aligned routing, not on the message bytes, the keys, or the
sector number.

Per-sector cycle counts:
* T-derivation: ~12 cycles (one AES on the sector number with k2).
* Per data block: ~12 cycles (one AES on the XOR-tweaked block with k1).
* CTS overhead: ~12 cycles (one extra AES on the spliced final block).

**What this is intended to protect (not evaluated)**: timing attacks
that observe completion latency to infer key, sector, or data bits. The
design is intended to have no path that takes a different number of
cycles depending on data values.

### 3. Bounded round counters

The internal AES round counter (0..10) and the block index counter
(0..full_blocks_w) are intended to be checked by SVA assertions that
fail the test if a counter runs past its expected range (not
independently confirmed).

## What is NOT covered (be honest)

This list is deliberately exhaustive so users can evaluate fit:

- **Differential power analysis (DPA)** on the AES round update or the
  tweak register: the working state and the GF(2^128) alpha-multiplier
  inputs are unmasked. A power attacker measuring leakage at the FF
  boundary can mount standard CPA / DPA against intermediate values.
  Mitigation requires masked AES (e.g., threshold implementation,
  RAMBAM, domain-oriented masking) — not included in this repository.
- **Electromagnetic (EM) analysis** and **template attacks**: not
  specifically countered. There is no power balancing, no differential
  routing, no constant-Hamming-weight encoding.
- **Fault injection** on the round counter, AES state, the tweak
  register, or the FSM: a flipped bit can corrupt the output. No
  duplicated-counter / parity-protected register variant is included;
  that is on the roadmap.
- **Cache / micro-architectural side channels**: not applicable (this
  is RTL, not software). However, if you place this core into a system
  with a shared bus or shared memory, those channels can leak through
  the surrounding fabric.
- **Sector-swap / replay attacks**: XTS does NOT protect against these
  by design. See the warning at the top of this document.
- **Tampering / authentication**: XTS is NOT an AEAD. See the warning
  at the top.
- **Invasive attacks** (decap, microprobing) are entirely out of scope.

If your deployment threat model includes any of the above and the rest
of your system relies on integrity, this core is not enough on its own.

## Compliance claims

- **IEEE Std 1619-2018 conformance**: not validated. The RTL implements
  the IEEE 1619 algorithm (not validated) for the AES-128 / 256-bit
  XTS-key variant (`k1` 128 bits + `k2` 128 bits), including ciphertext
  stealing per §5.3.1. The following checks are included in the
  testbench; results not independently confirmed:
  * IEEE 1619-2018 Annex B Vectors 1, 2, 3, and 4 (the 32-byte and
    512-byte AES-128 cases).
  * 100 random (k1, k2, sector, plaintext) tuples generated with
    `cryptography.hazmat.primitives.ciphers.modes.XTS` (which uses
    OpenSSL).
  * A 4-KB-sector round-trip (the canonical full-disk-encryption sector
    size) plus dedicated CTS round-trip cases (lengths 17, 23, 31).
- **NIST CAVP test certificate**: NOT obtained. CAVP validation
  requires a NIST-accredited testing lab. The published IEEE 1619
  vectors and the Python `cryptography` reference vectors are included
  in the testbench; results not independently confirmed.
- **FIPS-140-3 certification**: NOT claimed. AES-XTS is on the
  FIPS 140-3 approved-algorithm list; achieving an actual FIPS-140-3
  certificate requires a full module evaluation including
  side-channel and tamper response — not part of this product.
- **Common Criteria**: not evaluated.
- **TCG OPAL / OPAL 2 / Pyrite suitability**: this core implements the
  cryptographic primitive used by OPAL self-encrypting drives, but
  the OPAL command set, key-management protocol, secure-boot
  integration, and authentication are out of scope and must be
  implemented by the integrator.

## Test methodology used to validate the security claims

The Verilator testbenches contain the checks below. The checks are
included; results not independently confirmed.

1. **Functional correctness on IEEE 1619 published vectors**:
   `make test`. The testbench includes Vectors 1, 2, 3, and 4 from IEEE
   Std 1619-2018 Annex B verbatim.
2. **Cross-validation against Python `cryptography`**: the testbench
   includes 100 randomly-generated (k1, k2, sector, length) tuples,
   each encrypted by the Python reference and replayed through the
   DUT; the output must match exactly. Lengths cover edge cases
   (16, aligned-multi-block, CTS-partial 17..31, and 4096 B for the
   real-world FDE case).
3. **Sector boundary**: a full 4-KB sector (32 blocks) is encrypted,
   decrypted, and round-trip-verified.
4. **CTS round-trips**: lengths 17, 23, 31 are encrypted and
   decrypted, the round-trip output must match the input.
5. **SVA protocol invariants, intended to be checked on every cycle**: see
   `tb/aes_xts_assertions.sv`. Properties include:
   - `data_ready_o` only rises after `init_i` has been seen.
   - `result_o` is stable while `result_valid_o`.
   - `result_last_o` pulses exactly once per session.
   - The session finishes within a generous latency bound (8192 cycles)
     to catch a stuck FSM.
   - `data_ready_o` cannot be high during `init_i` (T must derive first).
6. **Functional coverage**: 10 bins (encrypt / decrypt modes,
   single-block, multi-block-aligned, CTS, 4-KB sector, back-to-back
   sessions, idle, partial-last, full-last). Coverage report printed
   at end of `make test`.

We do NOT run experimental DPA / CPA against a real bitstream. The
constant-time claim is **design intent**, derived from the structure of
the algorithm; not evaluated. An experimentally verified claim would
require an FPGA, an oscilloscope, and a trace-collection campaign
measured in days or weeks; none has been done.

## How to use the core safely

1. **Use unique sector numbers.** A storage device that re-uses the
   same sector number for different logical addresses negates XTS's
   per-sector tweak property. Map LBA -> sector number 1:1 and never
   reuse.
2. **Hold `rst_ni` low for at least 4 cycles** after power-on and
   before the first command.
3. **Wipe k1 and k2 from registers after device shutdown.** The
   wrapper does not do this automatically (the working-state
   registers retain post-op state until the next `init_i`).
4. **Layer integrity on top of XTS.** XTS is confidentiality-only; a
   complete storage stack adds per-sector MACs (HMAC-SHA-256 + a
   monotonic counter) or filesystem-level integrity (BTRFS, ZFS).
5. The core is not a substitute for protocol-level measures like
   replay protection, key rotation, or secure-erase. Wrap it in a
   real storage-encryption stack (LUKS2, BitLocker FVEK, TCG OPAL).

## Reporting issues

Found a bug, a side channel we missed, or a discrepancy with IEEE
1619-2018? Open a GitHub issue; do not post confidential details in it.
Coordinated disclosure welcome. We do not currently offer a bug bounty.
