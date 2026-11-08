// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// IEEE Std 1619-2018 Annex B "XTS-AES test vectors", Vectors 1..5
// (the AES-128 / 256-bit-XTS-key cases). The harness in sim_main.cpp
// includes the same vectors as inline byte arrays; this file is kept
// for non-Verilator simulators (Vivado xsim, ModelSim/Questa) that
// prefer reading vectors from SV literals.
//
// Each vector specifies: k1, k2, sector (LE bytes), plaintext, expected
// ciphertext, length. Lengths are all multiples of 16 bytes (32-512 B);
// CTS exercising is on the random vectors and a dedicated CTS test in
// the C++ harness.

`ifndef AES_XTS_IEEE1619_VECTORS_SV
`define AES_XTS_IEEE1619_VECTORS_SV

package ieee1619_vectors_pkg;

  // Vector 1: 32-byte plaintext, sector 0, all-zero keys.
  // From IEEE 1619-2018 Annex B Vector 1.
  function automatic logic [255:0] v1_k();
    v1_k = 256'h0000000000000000000000000000000000000000000000000000000000000000;
  endfunction

  function automatic logic [127:0] v1_sec();
    v1_sec = 128'h00000000000000000000000000000000;
  endfunction

  function automatic logic [255:0] v1_pt();
    v1_pt = 256'h00000000000000000000000000000000_00000000000000000000000000000000;
  endfunction

  function automatic logic [255:0] v1_ct();
    // Expected: 917cf69ebd68b2ec9b9fe9a3eadda692 cd43d2f59598ed858c02c2652fbf922e
    v1_ct = 256'h917cf69ebd68b2ec9b9fe9a3eadda692_cd43d2f59598ed858c02c2652fbf922e;
  endfunction

  // Vector 2: 32-byte plaintext, sector 0x33...
  function automatic logic [255:0] v2_k();
    // k1 || k2 (each 128 bits)
    v2_k = 256'h11111111111111111111111111111111_22222222222222222222222222222222;
  endfunction

  function automatic logic [127:0] v2_sec();
    v2_sec = 128'h33333333330000000000000000000000;  // sector 0x33333333_33 LE
  endfunction

  function automatic logic [255:0] v2_pt();
    v2_pt = 256'h44444444444444444444444444444444_44444444444444444444444444444444;
  endfunction

  function automatic logic [255:0] v2_ct();
    v2_ct = 256'hc454185e6a16936e39334038acef838b_fb186fff7480adc4289382ecd6d394f0;
  endfunction

endpackage

`endif
