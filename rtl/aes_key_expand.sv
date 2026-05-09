// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// AES-128 key expansion (FIPS-197 section 5.2).
// One round-key per cycle, computed combinationally from the previous round-key.
//
// Round 0  -> raw cipher key
// Round N  -> KeyExpansion step applied N times
//
// rcon_i is the round constant for the round being produced (rcon for output).
// For round n in [1..10], rcon = { rc[n], 24'h0 } where rc[1]=01, rc[2]=02, ..., rc[10]=36.

module aes_key_expand (
  input  logic [127:0] round_key_i,  // previous round key (W[4n-4..4n-1])
  input  logic [7:0]   rcon_i,       // round constant byte for new round
  output logic [127:0] round_key_o   // new round key
);

  // Word layout: round_key_i = { W0, W1, W2, W3 }, MSB first.
  logic [31:0] w0, w1, w2, w3;
  assign w0 = round_key_i[127:96];
  assign w1 = round_key_i[ 95:64];
  assign w2 = round_key_i[ 63:32];
  assign w3 = round_key_i[ 31: 0];

  // RotWord(W3): cyclic byte rotation left by 1 -> { W3[23:0], W3[31:24] }
  logic [31:0] rot_w3;
  assign rot_w3 = { w3[23:0], w3[31:24] };

  // SubWord(rot_w3): apply S-box to each byte
  logic [31:0] sub_w3;
  aes_sbox u_sb0 (.in_i(rot_w3[31:24]), .out_o(sub_w3[31:24]));
  aes_sbox u_sb1 (.in_i(rot_w3[23:16]), .out_o(sub_w3[23:16]));
  aes_sbox u_sb2 (.in_i(rot_w3[15: 8]), .out_o(sub_w3[15: 8]));
  aes_sbox u_sb3 (.in_i(rot_w3[ 7: 0]), .out_o(sub_w3[ 7: 0]));

  // XOR with Rcon (only top byte non-zero)
  logic [31:0] g_w3;
  assign g_w3 = sub_w3 ^ { rcon_i, 24'h0 };

  // New words
  logic [31:0] nw0, nw1, nw2, nw3;
  assign nw0 = w0 ^ g_w3;
  assign nw1 = w1 ^ nw0;
  assign nw2 = w2 ^ nw1;
  assign nw3 = w3 ^ nw2;

  assign round_key_o = { nw0, nw1, nw2, nw3 };

endmodule
