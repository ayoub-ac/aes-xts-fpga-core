// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// GF(2^128) multiply-by-alpha (XTS-AES tweak progression, IEEE Std
// 1619-2018 §5.1).
//
// XTS uses the polynomial p(x) = x^128 + x^7 + x^2 + x + 1, encoded by
// the constant byte 0x87 (the low byte of the reduction). Multiplying a
// 128-bit element T by alpha = x is, in the per-byte little-endian-bit
// convention used by IEEE 1619, a one-bit left shift of the bit stream
// formed by t[0], t[1], ..., t[15] -- where each byte's bit 0 is the
// "earliest" bit in the stream. Equivalently:
//
//   carry_in = 0
//   for i in 0..15:
//       bit_out  = (t[i] >> 7) & 1            // takes the byte's high bit
//       t[i]     = ((t[i] << 1) | carry_in) & 0xff
//       carry_in = bit_out
//   if carry_in == 1:
//       t[0] ^= 0x87                          // reduce by p(x)
//
// Note this is NOT the GHASH polynomial (x^128 + x^7 + x^2 + x + 1 is
// the same polynomial but GCM treats the bit ordering with bit 0 at
// the leftmost position; XTS treats bit 0 at the rightmost position of
// each byte). Implementations are therefore byte-shift duals of each
// other; we cannot reuse `ghash_core.sv` directly.
//
// Storage convention (matches the rest of this core and the AES side):
// byte 0 of the tweak block lives in bits [127:120] of the 128-bit
// register, byte 15 in bits [7:0]. The shift therefore walks from the
// MOST-significant byte of the register down to the least.
//
// This module is purely combinational. The XTS top latches the result
// every cycle a new tweak is needed (one multiply per AES block).

module gf128_mul_alpha (
  input  logic [127:0] t_i,      // current tweak T_j
  output logic [127:0] t_o       // T_{j+1} = T_j * alpha mod p
);

  // Unpack to bytes; b[0] = t_i[127:120], b[15] = t_i[7:0].
  logic [7:0] b   [0:15];
  logic [7:0] nb  [0:15];
  logic [15:0] cout;

  genvar gi;
  generate
    for (gi = 0; gi < 16; gi++) begin : g_unpack
      assign b[gi] = t_i[127 - 8*gi -: 8];
    end
  endgenerate

  // Carry chain across bytes 0..15 (high register byte -> low register byte).
  // cout[gi] is the bit shifted OUT of byte gi (its MSB before the shift).
  // The carry INTO byte gi is cout[gi-1] (cout[-1] = 0).
  generate
    for (gi = 0; gi < 16; gi++) begin : g_shift
      if (gi == 0) begin : g_first
        assign nb[gi]    = {b[gi][6:0], 1'b0};
        assign cout[gi]  = b[gi][7];
      end else begin : g_rest
        assign nb[gi]    = {b[gi][6:0], cout[gi-1]};
        assign cout[gi]  = b[gi][7];
      end
    end
  endgenerate

  // Reduction: if the bit shifted out of byte 15 is 1, XOR 0x87 into
  // byte 0 of the new value.
  logic [7:0] reduced0;
  assign reduced0 = nb[0] ^ (cout[15] ? 8'h87 : 8'h00);

  // Pack result back into 128-bit register.
  generate
    for (gi = 0; gi < 16; gi++) begin : g_pack
      if (gi == 0) begin : g_p0
        assign t_o[127 - 8*gi -: 8] = reduced0;
      end else begin : g_pn
        assign t_o[127 - 8*gi -: 8] = nb[gi];
      end
    end
  endgenerate

endmodule
