# Port description

Detailed handshake protocol and timing for `aes_xts_top`.

## Reset

`rst_ni` is **synchronous active-low**. Hold it low for at least 4
clock cycles before the first command. After de-assertion, the core is
in `T_IDLE` with `init_ready_o = 1`.

```
clk_i      __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
rst_ni     ‾‾‾‾‾‾‾|_______________________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾
init_ready_o      X X X X X X X X X X X X X 1 1 1 1 1 1
```

## Session start

A new sector encryption / decryption is initiated by pulsing `init_i`
for one cycle together with the keys, sector number, mode, and total
byte count. The core internally:

1. Captures `k1_i`, `k2_i`, `sector_i`, `mode_i`, `total_bytes_i`.
2. Encrypts `sector_i` with `k2_i` to derive the tweak base
   `T = AES_enc(k2, sector)` (~12 cycles).
3. Begins accepting data blocks.

```
clk_i               |‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
init_ready_o        ‾‾‾|___________________________________
init_i              ___|‾‾|_____________________________________
k1_i / k2_i         ___|valid|___________________________________
sector_i            ___|valid|___________________________________
mode_i              ___|valid|___________________________________
total_bytes_i       ___|valid|___________________________________
                    (T derive ~12 cycles)
data_ready_o        _________________________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
```

`init_ready_o` is high when the core can accept a new `init_i`, which
includes both `T_IDLE` (post-reset / post-clean) and `T_DONE` (after a
prior session has finalised). Driving `init_i` while
`init_ready_o = 0` is ignored.

## Data streaming

Each data block is 16 bytes for full blocks, 1..15 bytes for the
trailing partial block of a CTS sector.

```
clk_i               |‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
data_ready_o        ‾‾|_______________________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
data_valid_i        |‾‾|_____________________________________
data_i              |b0 |_____________________________________
data_byte_count_i   |16 |_____________________________________
data_last_i         |0  |_____________________________________
                    (AES ~12 cycles)
result_valid_o      _________________________|‾‾|________
result_o            _________________________|r0 |________
result_ready_i      _____________________________|‾‾|____
```

For aligned sectors (length is a multiple of 16), every input block
emits a 16-byte result block in lock-step. For CTS sectors, the LAST
TWO output blocks are emitted in swapped order:

1. The first CTS output is 16 bytes (`result_byte_count_o = 16`,
   `result_last_o = 0`).
2. The second CTS output is `total_bytes_i % 16` bytes
   (`result_byte_count_o = trailing`, `result_last_o = 1`).

The integrator stitches the bytes by concatenating
`result_o[0 .. result_byte_count_o-1]` for each emitted block in order.

`data_last_i = 1` together with `data_valid_i = 1` marks the final
block. For CTS the last user-supplied block has `data_byte_count_i < 16`
and `data_last_i = 1`. For aligned the last block has
`data_byte_count_i = 16` and `data_last_i = 1`.

## Sector number encoding

`sector_i[127:0]` holds the 128-bit data-unit sequence number in
**little-endian byte order** per IEEE Std 1619-2018:

* `sector_i = 128'd0` -> bytes `00 00 ... 00` (sector 0)
* `sector_i = 128'd1` -> bytes `01 00 ... 00` (sector 1, LE)
* `sector_i = 128'd0xdead` -> bytes `ad de 00 ... 00` (LE)

This matches Python `cryptography.hazmat.primitives.ciphers.modes.XTS`,
OpenSSL `EVP_aes_128_xts`, and Linux `dm-crypt --tweak-mode=plain64`
conventions.

## Mode select (`mode_i`)

| Encoding | Mode    | Use                                              |
|----------|---------|--------------------------------------------------|
| `1'b0`   | ENCRYPT | Caller feeds plaintext, receives ciphertext      |
| `1'b1`   | DECRYPT | Caller feeds ciphertext, receives plaintext      |

The hardware operations are identical for both modes (one AES per block
on `data XOR T`, output XOR `T`); the only difference is the AES
direction (`aes_core.encrypt_i` is wired to `~mode_i`). For decrypt CTS
sectors, the tweak schedule on the LAST TWO blocks is swapped per
IEEE 1619-2018 §5.3.1; this is handled internally by the FSM.

## Endianness

All wide buses except `sector_i` use **big-endian** byte ordering,
matching IEEE 1619 / NIST byte-string conventions:

- `k1_i[127:120]` is byte 0 of the data key.
- `k2_i[127:120]` is byte 0 of the tweak key.
- `data_i[127:120]` is byte 0 of the input block.
- `result_o[127:120]` is byte 0 of the output block.

`sector_i[7:0]` is byte 0 of the LITTLE-endian-encoded sector number
(see "Sector number encoding" above).

This matches the convention used by Python's `cryptography` library and
by reference implementations in OpenSSL when serialising AES-XTS output.

## Latency summary

For a sector with `N` bytes (`F = floor(N/16)` full blocks plus
`T = N mod 16` trailing bytes):

| Phase                          | Cycles                     |
|--------------------------------|----------------------------|
| Init capture                   | 1                          |
| T derive (AES on sector_i)     | ~12                        |
| Per data block                 | ~12 (AES) + 1 (emit handshake) |
| Number of full blocks          | `F` (or `F-1` if CTS)      |
| CTS overhead (if `T > 0`)      | ~14 (one extra AES + 2 emit handshakes) |
| Total (rough)                  | `~13 + F * 13 + (T > 0 ? 14 : 0)` cycles |

For a 4-KB sector (32 blocks, aligned), this is about 430 cycles, i.e.
~4.3 microseconds at 100 MHz (unverified estimates). The throughput is
dominated by the AES core (12 cycles per block). No pipelined AES
variant is included in this repository.
