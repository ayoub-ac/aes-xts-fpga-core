// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// AES single-round combinational logic (FIPS-197 section 5).
//
// Forward round (encrypt):
//   state -> SubBytes -> ShiftRows -> MixColumns -> AddRoundKey
//   final round (round 10) skips MixColumns
//
// Inverse round (decrypt) using "Equivalent Inverse Cipher" structure simplified
// here as per-round InvShiftRows + InvSubBytes + AddRoundKey + InvMixColumns,
// with first decrypt round skipping InvMixColumns. We implement the classic
// (non-equivalent) inverse cipher: state -> InvShiftRows -> InvSubBytes ->
// AddRoundKey -> InvMixColumns. This matches FIPS-197 section 5.3 ordering.
//
// The state is 128 bits laid out as the AES state matrix in column-major order,
// MSB-first byte 0 = state[0,0]. We use byte index s[i] where i = row + 4*col.

module aes_round (
  input  logic [127:0] state_i,
  input  logic [127:0] round_key_i,
  input  logic         encrypt_i,    // 1 = forward, 0 = inverse
  input  logic         final_round_i, // 1 = skip MixColumns / InvMixColumns
  output logic [127:0] state_o
);

  // ---------- Helpers ---------------------------------------------------------
  // Byte access: byte index 0..15. We store state MSB-first so byte 0 is bits [127:120].
  // Rearrange as s[i] = state_i[127-8*i -: 8].

  function automatic logic [7:0] xtime (input logic [7:0] b);
    xtime = {b[6:0], 1'b0} ^ (b[7] ? 8'h1b : 8'h00);
  endfunction

  // Constant GF(2^8) multipliers for InvMixColumns coefficients {0e,0b,0d,09}.
  // Decomposed as nested xtime to match the round structure with minimal LUTs.
  //   2a = xtime(a),  4a = xtime(2a),  8a = xtime(4a)
  //   9a = 8a ^ a
  //   ba = 8a ^ 2a ^ a
  //   da = 8a ^ 4a ^ a
  //   ea = 8a ^ 4a ^ 2a

  // ---------- Unpack state ----------------------------------------------------
  logic [7:0] s [0:15];
  genvar gi;
  generate
    for (gi = 0; gi < 16; gi++) begin : g_unpack
      assign s[gi] = state_i[127 - 8*gi -: 8];
    end
  endgenerate

  // ---------- ENCRYPT PATH ----------------------------------------------------
  // SubBytes
  logic [7:0] sb [0:15];
  generate
    for (gi = 0; gi < 16; gi++) begin : g_sb
      aes_sbox u_sb (.in_i(s[gi]), .out_o(sb[gi]));
    end
  endgenerate

  // ShiftRows on sb -> sr
  // Layout: byte index = row + 4*col. row 0 unchanged, row 1 << 1, row 2 << 2, row 3 << 3.
  logic [7:0] sr [0:15];
  // Row 0: sr[0,4,8,12] = sb[0,4,8,12]
  assign sr[0]  = sb[0];
  assign sr[4]  = sb[4];
  assign sr[8]  = sb[8];
  assign sr[12] = sb[12];
  // Row 1: shift left 1. sr[r=1,col c] = sb[r=1, col (c+1) mod 4]
  assign sr[1]  = sb[5];
  assign sr[5]  = sb[9];
  assign sr[9]  = sb[13];
  assign sr[13] = sb[1];
  // Row 2: shift left 2
  assign sr[2]  = sb[10];
  assign sr[6]  = sb[14];
  assign sr[10] = sb[2];
  assign sr[14] = sb[6];
  // Row 3: shift left 3 (= right 1)
  assign sr[3]  = sb[15];
  assign sr[7]  = sb[3];
  assign sr[11] = sb[7];
  assign sr[15] = sb[11];

  // MixColumns on sr -> mc
  logic [7:0] mc [0:15];
  genvar gc;
  generate
    for (gc = 0; gc < 4; gc++) begin : g_mc
      logic [7:0] a0, a1, a2, a3;
      assign a0 = sr[4*gc + 0];
      assign a1 = sr[4*gc + 1];
      assign a2 = sr[4*gc + 2];
      assign a3 = sr[4*gc + 3];
      assign mc[4*gc + 0] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3;
      assign mc[4*gc + 1] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3;
      assign mc[4*gc + 2] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3);
      assign mc[4*gc + 3] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);
    end
  endgenerate

  // Encrypt result before AddRoundKey: pick mc unless final round, then sr
  logic [127:0] enc_pre_ark;
  generate
    for (gi = 0; gi < 16; gi++) begin : g_enc_pre
      assign enc_pre_ark[127 - 8*gi -: 8] = final_round_i ? sr[gi] : mc[gi];
    end
  endgenerate

  logic [127:0] enc_out;
  assign enc_out = enc_pre_ark ^ round_key_i;

  // ---------- DECRYPT PATH ----------------------------------------------------
  // InvShiftRows on s -> isr
  logic [7:0] isr [0:15];
  // Row 0 unchanged
  assign isr[0]  = s[0];
  assign isr[4]  = s[4];
  assign isr[8]  = s[8];
  assign isr[12] = s[12];
  // Row 1: shift right 1 (col c sources from col (c-1) mod 4)
  assign isr[1]  = s[13];
  assign isr[5]  = s[1];
  assign isr[9]  = s[5];
  assign isr[13] = s[9];
  // Row 2: shift right 2
  assign isr[2]  = s[10];
  assign isr[6]  = s[14];
  assign isr[10] = s[2];
  assign isr[14] = s[6];
  // Row 3: shift right 3 (= left 1)
  assign isr[3]  = s[7];
  assign isr[7]  = s[11];
  assign isr[11] = s[15];
  assign isr[15] = s[3];

  // InvSubBytes
  logic [7:0] isb [0:15];
  generate
    for (gi = 0; gi < 16; gi++) begin : g_isb
      aes_inv_sbox u_isb (.in_i(isr[gi]), .out_o(isb[gi]));
    end
  endgenerate

  // AddRoundKey to get pre-InvMixColumns intermediate
  logic [127:0] dec_after_ark;
  generate
    for (gi = 0; gi < 16; gi++) begin : g_dec_ark
      assign dec_after_ark[127 - 8*gi -: 8] = isb[gi] ^ round_key_i[127 - 8*gi -: 8];
    end
  endgenerate

  // InvMixColumns on dec_after_ark
  // Coefficients: 0x0e, 0x0b, 0x0d, 0x09
  logic [7:0] dak [0:15];
  generate
    for (gi = 0; gi < 16; gi++) begin : g_dak
      assign dak[gi] = dec_after_ark[127 - 8*gi -: 8];
    end
  endgenerate

  logic [7:0] imc [0:15];
  generate
    for (gc = 0; gc < 4; gc++) begin : g_imc
      logic [7:0] b0, b1, b2, b3;
      logic [7:0] x2_0, x4_0, x8_0;
      logic [7:0] x2_1, x4_1, x8_1;
      logic [7:0] x2_2, x4_2, x8_2;
      logic [7:0] x2_3, x4_3, x8_3;
      logic [7:0] m9_0, mb_0, md_0, me_0;
      logic [7:0] m9_1, mb_1, md_1, me_1;
      logic [7:0] m9_2, mb_2, md_2, me_2;
      logic [7:0] m9_3, mb_3, md_3, me_3;

      assign b0 = dak[4*gc + 0];
      assign b1 = dak[4*gc + 1];
      assign b2 = dak[4*gc + 2];
      assign b3 = dak[4*gc + 3];

      assign x2_0 = xtime(b0);  assign x4_0 = xtime(x2_0);  assign x8_0 = xtime(x4_0);
      assign x2_1 = xtime(b1);  assign x4_1 = xtime(x2_1);  assign x8_1 = xtime(x4_1);
      assign x2_2 = xtime(b2);  assign x4_2 = xtime(x2_2);  assign x8_2 = xtime(x4_2);
      assign x2_3 = xtime(b3);  assign x4_3 = xtime(x2_3);  assign x8_3 = xtime(x4_3);

      assign m9_0 = x8_0 ^ b0;          assign mb_0 = x8_0 ^ x2_0 ^ b0;
      assign md_0 = x8_0 ^ x4_0 ^ b0;   assign me_0 = x8_0 ^ x4_0 ^ x2_0;
      assign m9_1 = x8_1 ^ b1;          assign mb_1 = x8_1 ^ x2_1 ^ b1;
      assign md_1 = x8_1 ^ x4_1 ^ b1;   assign me_1 = x8_1 ^ x4_1 ^ x2_1;
      assign m9_2 = x8_2 ^ b2;          assign mb_2 = x8_2 ^ x2_2 ^ b2;
      assign md_2 = x8_2 ^ x4_2 ^ b2;   assign me_2 = x8_2 ^ x4_2 ^ x2_2;
      assign m9_3 = x8_3 ^ b3;          assign mb_3 = x8_3 ^ x2_3 ^ b3;
      assign md_3 = x8_3 ^ x4_3 ^ b3;   assign me_3 = x8_3 ^ x4_3 ^ x2_3;

      assign imc[4*gc + 0] = me_0 ^ mb_1 ^ md_2 ^ m9_3;
      assign imc[4*gc + 1] = m9_0 ^ me_1 ^ mb_2 ^ md_3;
      assign imc[4*gc + 2] = md_0 ^ m9_1 ^ me_2 ^ mb_3;
      assign imc[4*gc + 3] = mb_0 ^ md_1 ^ m9_2 ^ me_3;
    end
  endgenerate

  // Final decrypt round skips InvMixColumns -> output dec_after_ark.
  logic [127:0] dec_out;
  generate
    for (gi = 0; gi < 16; gi++) begin : g_dec_out
      assign dec_out[127 - 8*gi -: 8] = final_round_i ? dak[gi] : imc[gi];
    end
  endgenerate

  // ---------- Mode select -----------------------------------------------------
  assign state_o = encrypt_i ? enc_out : dec_out;

endmodule
