// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// AES-XTS-128 top (IEEE Std 1619-2018, "XTS-AES" tweakable cipher used
// by every modern full-disk encryption layer: BitLocker, FileVault 2,
// LUKS / dm-crypt, eCryptfs, ZFS native encryption, and OPAL self-
// encrypting drives).
//
// Construction (per IEEE 1619-2018 §5.3):
//
//   T   = AES_enc(k2, IV)                  // tweak base, 128-bit, derived
//                                          //   ONCE per data unit (sector).
//                                          //   IV is the 128-bit data-unit
//                                          //   sequence number, encoded in
//                                          //   little-endian byte order.
//   For block j = 0, 1, ..., m-1 in the sector:
//     T_j  = T * alpha^j mod p(x)          // alpha-multiply for tweak
//                                          //   progression. p(x) is
//                                          //   x^128 + x^7 + x^2 + x + 1
//                                          //   (constant byte 0x87, the
//                                          //   IEEE 1619 polynomial - NOT
//                                          //   the GCM/GHASH polynomial).
//     CC_j = P_j XOR T_j                   // pre-whitening
//     C_j  = AES_enc(k1, CC_j) XOR T_j     // post-whitening
//
// Decrypt: AES_dec(k1, C_j XOR T_j) XOR T_j = P_j with the same T_j.
//
// Ciphertext stealing (CTS, IEEE 1619-2018 §5.3.1) for sectors whose
// length is not a multiple of 16 bytes is implemented per the standard:
// the last full block's ciphertext and the partial last block are
// "stolen" so the output length matches the input length exactly. The
// minimum data unit is 128 bits (16 B); a single partial block alone
// is undefined and rejected by callers in practice (the protocol layer
// guarantees >= 128 bits per data unit). This core supports lengths >=
// 16 B with arbitrary trailing partial bytes.
//
// Mode select:
//   mode_i = 1'b0  ENCRYPT      plaintext  -> ciphertext
//   mode_i = 1'b1  DECRYPT      ciphertext -> plaintext
//
// Streaming protocol:
//   1. Pulse init_i with k1_i / k2_i / sector_i / mode_i / total_bytes_i.
//      total_bytes_i is the byte length of this sector. If total_bytes_i
//      is a multiple of 16 (the universal real-world case for storage:
//      4096 byte sectors = 32x16 blocks), no CTS is performed.
//      Otherwise total_bytes_i must be >= 16 and CTS is engaged.
//   2. The core derives T = AES_enc(k2, sector) (~12 cycles), then
//      announces data_ready_o.
//   3. Stream 16-byte blocks via data_valid_i / data_i / data_byte_count_i /
//      data_last_i. Result blocks come out in lock-step on result_*.
//      For non-aligned sectors, the LAST full 128-bit block (the
//      penultimate input chunk) and the partial trailing block are
//      ciphertext-stolen internally; the caller still presents bytes in
//      order, and the core emits bytes in the canonical XTS-CTS order.
//
// Endianness: byte 0 of every 128-bit byte-stream port lives in bits
// [127:120]. The sector number sector_i[127:0] holds byte 0 in
// [7:0] (LITTLE-endian, per IEEE 1619-2018) so that
//   sector_i = 128'd0  -> bytes 00 00 ... 00 (sector 0)
//   sector_i = 128'd1  -> bytes 01 00 ... 00 (sector 1)
// This matches Python `cryptography.hazmat.primitives.ciphers.modes.XTS`
// and OpenSSL conventions.

module aes_xts_top (
  input  logic         clk_i,
  input  logic         rst_ni,

  // Session setup
  input  logic         init_i,
  input  logic [127:0] k1_i,           // data key
  input  logic [127:0] k2_i,           // tweak key
  input  logic [127:0] sector_i,       // 128-bit data-unit number, LE bytes
  input  logic         mode_i,         // 0 = encrypt, 1 = decrypt
  input  logic [15:0]  total_bytes_i,  // sector length in bytes (>=16
                                       //   when CTS engaged; multiple of 16
                                       //   for the aligned fast path).
  output logic         init_ready_o,

  // Plaintext / ciphertext streaming. data_byte_count_i is 16 for full
  // blocks and 1..15 for the trailing partial block of a CTS sector.
  input  logic         data_valid_i,
  input  logic [127:0] data_i,
  input  logic [4:0]   data_byte_count_i,
  input  logic         data_last_i,
  output logic         data_ready_o,

  // Result streaming. For aligned sectors result_byte_count_o is always
  // 16. For CTS sectors the last two emitted blocks have byte-counts
  // 16 (the stolen-from-prev result) and (total_bytes mod 16) (the
  // remaining partial). Caller stitches via result_byte_count_o /
  // result_last_o.
  output logic         result_valid_o,
  output logic [127:0] result_o,
  output logic [4:0]   result_byte_count_o,
  output logic         result_last_o,
  input  logic         result_ready_i
);

  localparam logic M_ENCRYPT = 1'b0;
  localparam logic M_DECRYPT = 1'b1;

  // ------------------------------------------------------------------
  // Single AES-128 core, sequenced by the FSM. Shared between:
  //   * T-derivation: AES_enc(k2, sector)
  //   * Data path:    AES_{enc|dec}(k1, ...)
  // The data-key vs tweak-key selection is muxed at AES `key_i` input.
  // ------------------------------------------------------------------
  logic         aes_valid_i;
  logic         aes_ready_o;
  logic [127:0] aes_data_i;
  logic [127:0] aes_data_o;
  logic         aes_valid_o;
  logic         aes_ready_i;
  logic         aes_encrypt_in;
  logic [127:0] aes_key_mux;

  aes_core u_aes (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .key_i    (aes_key_mux),
    .data_i   (aes_data_i),
    .encrypt_i(aes_encrypt_in),
    .valid_i  (aes_valid_i),
    .ready_o  (aes_ready_o),
    .data_o   (aes_data_o),
    .valid_o  (aes_valid_o),
    .ready_i  (aes_ready_i)
  );

  // ------------------------------------------------------------------
  // GF(2^128) alpha-multiplier (combinational).
  // ------------------------------------------------------------------
  logic [127:0] tweak_q;
  logic [127:0] tweak_next;

  gf128_mul_alpha u_gf (
    .t_i (tweak_q),
    .t_o (tweak_next)
  );

  // ------------------------------------------------------------------
  // Sector-number to AES input. IEEE 1619 encodes the sector number as
  // a little-endian byte sequence; our wide bus has byte 0 in bits
  // [127:120], so we byte-reverse on capture.
  // ------------------------------------------------------------------
  function automatic logic [127:0] le_to_be (input logic [127:0] le);
    integer i;
    le_to_be = 128'd0;
    for (i = 0; i < 16; i = i + 1) begin
      // sector_i[7:0] is byte 0 of the LE sector number; place it at
      // [127:120] of the AES input (big-endian byte 0 position).
      le_to_be[127 - 8*i -: 8] = le[8*i +: 8];
    end
  endfunction

  // Big-endian byte-mask: keep first `bcb` bytes (byte 0 .. bcb-1).
  function automatic logic [127:0] be_byte_mask128(input logic [4:0] bcb);
    integer i;
    be_byte_mask128 = 128'd0;
    for (i = 0; i < 16; i = i + 1) begin
      if (i < bcb) be_byte_mask128[127 - 8*i -: 8] = 8'hff;
      else         be_byte_mask128[127 - 8*i -: 8] = 8'h00;
    end
  endfunction

  // Splice helper: first `bc` bytes from hi_src, remaining 16-bc from
  // lo_src. Used to build the CTS final-block AES input.
  function automatic logic [127:0] splice_be (input logic [127:0] hi_src,
                                              input logic [127:0] lo_src,
                                              input logic [4:0]   bc);
    integer i;
    splice_be = 128'd0;
    for (i = 0; i < 16; i = i + 1) begin
      if (i < bc) splice_be[127 - 8*i -: 8] = hi_src[127 - 8*i -: 8];
      else        splice_be[127 - 8*i -: 8] = lo_src[127 - 8*i -: 8];
    end
  endfunction

  // ------------------------------------------------------------------
  // Session registers
  // ------------------------------------------------------------------
  logic [127:0] sess_k1_q;
  logic [127:0] sess_k2_q;
  logic [127:0] sess_sector_be_q;
  logic         sess_mode_q;
  logic [15:0]  sess_total_q;

  // Block index (0-based). Counts AES data-block invocations completed.
  // Equals the number of T*alpha^j progressions to form the next tweak.
  logic [11:0] blk_idx_q;
  logic [11:0] full_blocks_w;
  logic [3:0]  trailing_w;
  logic        cts_needed_w;
  assign full_blocks_w = sess_total_q[15:4];
  assign trailing_w    = sess_total_q[3:0];
  assign cts_needed_w  = (trailing_w != 4'd0);

  // ------------------------------------------------------------------
  // FSM phases
  //
  //   T_IDLE        : waiting for init.
  //   T_DERIVE_T    : run AES_enc(k2, sector) to obtain T.
  //   T_RX          : ready to accept the next 16-byte block.
  //   T_AES_FULL    : AES on a full 16-byte block (input XOR tweak_q).
  //   T_OUT         : drive result_o; on handshake advance tweak_q.
  //   T_CTS_HOLD    : (CTS only) penultimate full-block AES is done but
  //                   result is HELD. Wait for partial last block.
  //   T_CTS_AES     : AES on splice(partial || stolen-bytes) XOR T,
  //                   T being T_m for encrypt or T_{m-1} for decrypt.
  //   T_CTS_EMIT_FULL: emit the CTS first output (16 bytes of result).
  //   T_CTS_EMIT_PARTIAL: emit the trailing partial bytes (truncated
  //                   from the held penultimate full-block raw result).
  //   T_DONE        : sector finished; wait for next init.
  // ------------------------------------------------------------------

  typedef enum logic [3:0] {
    T_IDLE             = 4'd0,
    T_DERIVE_T         = 4'd1,
    T_RX               = 4'd2,
    T_AES_FULL         = 4'd3,
    T_OUT              = 4'd4,
    T_CTS_HOLD         = 4'd5,
    T_CTS_AES          = 4'd6,
    T_CTS_EMIT_FULL    = 4'd7,
    T_CTS_EMIT_PARTIAL = 4'd8,
    T_DONE             = 4'd9
  } tstate_e;

  tstate_e tstate_q, tstate_d;

  // Captured input data block.
  logic [127:0] data_buf_q;
  logic [4:0]   data_bc_q;
  logic         data_last_buf_q;

  // CTS hold: the raw AES output of the penultimate full block, kept so
  // we can splice its high-bytes into the partial-block AES input AND
  // emit its low-bytes as the final partial output.
  // For encrypt: cts_held_q = AES_enc(k1, P_{m-1} XOR T_{m-1}) XOR T_{m-1}
  //              (== C_{m-1} in the spec; we steal high bytes for splice).
  // For decrypt: cts_held_q = AES_dec(k1, C_{m-1} XOR T_m) XOR T_m
  //              -- which after we apply XOR-T-tweak inside the splice
  //              yields the right PP'.
  logic [127:0] cts_held_q;
  logic [4:0]   cts_partial_bc_q;

  // Scratch tweak storage (T_{m-1} when we need to swap during decrypt CTS).
  logic [127:0] cts_t_prev_q;

  // Result registers
  logic [127:0] result_q;
  logic [4:0]   result_bc_q;
  logic         result_last_q;
  logic         result_valid_q;

  // ------------------------------------------------------------------
  // Decision: when in T_RX accepting a block, is this the last FULL
  // block of a CTS sector (the penultimate input chunk; data_last_i = 0
  // since the partial chunk is still upstream)?
  //   blk_idx_q is the index of the block we're about to AES.
  //   For aligned sector: full_blocks_w = total/16, last = blk_idx_q == full_blocks_w-1
  //                       and data_last_i = 1.
  //   For CTS sector: full_blocks_w = floor(total/16); the penultimate
  //                   FULL block has blk_idx_q == full_blocks_w-1; the
  //                   PARTIAL last block has data_byte_count_i < 16 and
  //                   data_last_i = 1, blk_idx_q == full_blocks_w (we
  //                   skip its tweak because we route through T_CTS_*).
  // ------------------------------------------------------------------

  // ------------------------------------------------------------------
  // AES key/encrypt direction selection
  // ------------------------------------------------------------------
  always_comb begin
    if (tstate_q == T_DERIVE_T) begin
      aes_key_mux    = sess_k2_q;
      aes_encrypt_in = 1'b1;
    end else begin
      aes_key_mux    = sess_k1_q;
      aes_encrypt_in = (sess_mode_q == M_ENCRYPT);
    end
  end

  // ------------------------------------------------------------------
  // Combinational FSM
  // ------------------------------------------------------------------
  logic [127:0] aes_pre_xor_w;
  logic [127:0] aes_post_xor_w;
  assign aes_pre_xor_w  = data_buf_q ^ tweak_q;
  assign aes_post_xor_w = aes_data_o ^ tweak_q;

  // For the CTS final AES the spliced input is XORed with the tweak
  // that AES uses on this pass. The held block's "raw AES output" was
  // post-XORed with cts_t_prev_q (so we recover raw by XOR'ing it back).
  // Composition for encrypt:
  //   AES input  = (data_buf_q || (cts_held_q[lo bytes])) XOR tweak_q
  //   where cts_held_q already has T_{m-1} XOR'ed in (it's C_{m-1}-shaped).
  //   Per spec the bytes "stolen" are exactly C_{m-1}'s low bytes, so
  //   the splice is fed verbatim and XORed with T_m at the AES input,
  //   then the result is XORed with T_m at the AES output -> Cm.
  // Composition for decrypt:
  //   The penultimate pass uses T_m as tweak (we do that BEFORE
  //   T_AES_FULL on the penultimate by pre-stepping tweak_q). The held
  //   value cts_held_q is then "Pm-1-shaped" with T_m-XOR-residue; we
  //   restore T_{m-1} as tweak_q before T_CTS_AES so the partial-block
  //   AES_dec sees T_{m-1}.
  logic [127:0] cts_aes_input_w;
  assign cts_aes_input_w = splice_be(data_buf_q, cts_held_q,
                                     cts_partial_bc_q) ^ tweak_q;

  always_comb begin
    tstate_d    = tstate_q;
    aes_valid_i = 1'b0;
    aes_data_i  = 128'd0;
    aes_ready_i = 1'b0;

    case (tstate_q)
      T_IDLE: begin
        if (init_i) tstate_d = T_DERIVE_T;
      end

      T_DERIVE_T: begin
        if (aes_ready_o) begin
          aes_data_i  = sess_sector_be_q;
          aes_valid_i = 1'b1;
        end
        if (aes_valid_o) begin
          aes_ready_i = 1'b1;
          tstate_d    = T_RX;
        end
      end

      T_RX: begin
        if (data_valid_i) begin
          // Two cases on entry:
          //   (a) full 16-byte block (typical): proceed to T_AES_FULL.
          //   (b) partial last block (CTS only) -- this should ONLY
          //       occur after T_CTS_HOLD; if it lands here it means the
          //       sector is invalid (single partial block alone). We
          //       still gracefully run AES on it XOR T_0 and emit, so
          //       the integrator does not deadlock.
          tstate_d = T_AES_FULL;
        end
      end

      T_AES_FULL: begin
        if (aes_ready_o) begin
          aes_data_i  = aes_pre_xor_w;
          aes_valid_i = 1'b1;
        end
        if (aes_valid_o) begin
          aes_ready_i = 1'b1;
          tstate_d    = T_OUT;
        end
      end

      T_OUT: begin
        // CTS penultimate full block: result was suppressed in seq;
        // route directly to T_CTS_HOLD without waiting for handshake.
        // (blk_idx_q has already been incremented for the held block.)
        if (cts_needed_w && (blk_idx_q == full_blocks_w)) begin
          tstate_d = T_CTS_HOLD;
        end else if (result_valid_q && result_ready_i) begin
          if (data_last_buf_q && !cts_needed_w) begin
            tstate_d = T_DONE;
          end else begin
            tstate_d = T_RX;
          end
        end
      end

      T_CTS_HOLD: begin
        if (data_valid_i) begin
          tstate_d = T_CTS_AES;
        end
      end

      T_CTS_AES: begin
        if (aes_ready_o) begin
          aes_data_i  = cts_aes_input_w;
          aes_valid_i = 1'b1;
        end
        if (aes_valid_o) begin
          aes_ready_i = 1'b1;
          tstate_d    = T_CTS_EMIT_FULL;
        end
      end

      T_CTS_EMIT_FULL: begin
        if (result_valid_q && result_ready_i) begin
          tstate_d = T_CTS_EMIT_PARTIAL;
        end
      end

      T_CTS_EMIT_PARTIAL: begin
        if (result_valid_q && result_ready_i) begin
          tstate_d = T_DONE;
        end
      end

      T_DONE: begin
        if (init_i) tstate_d = T_DERIVE_T;
      end

      default: tstate_d = T_IDLE;
    endcase
  end

  // ------------------------------------------------------------------
  // Sequential
  // ------------------------------------------------------------------
  // Detect the moment we're about to run AES on the penultimate full
  // block of a CTS-DECRYPT sector. We need to pre-step tweak_q so AES
  // sees T_m on this pass. We restore T_{m-1} (= cts_t_prev_q) before
  // T_CTS_AES.
  logic decrypt_cts_penult_w;
  assign decrypt_cts_penult_w = cts_needed_w &&
                                (sess_mode_q == M_DECRYPT) &&
                                (blk_idx_q == full_blocks_w - 12'd1);

  // Detect we are entering T_AES_FULL from T_RX.
  logic enter_aes_full_w;
  assign enter_aes_full_w = (tstate_q == T_RX) && data_valid_i;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      tstate_q          <= T_IDLE;
      sess_k1_q         <= 128'd0;
      sess_k2_q         <= 128'd0;
      sess_sector_be_q  <= 128'd0;
      sess_mode_q       <= 1'b0;
      sess_total_q      <= 16'd0;
      tweak_q           <= 128'd0;
      data_buf_q        <= 128'd0;
      data_bc_q         <= 5'd0;
      data_last_buf_q   <= 1'b0;
      cts_held_q        <= 128'd0;
      cts_partial_bc_q  <= 5'd0;
      cts_t_prev_q      <= 128'd0;
      blk_idx_q         <= 12'd0;
      result_q          <= 128'd0;
      result_bc_q       <= 5'd0;
      result_last_q     <= 1'b0;
      result_valid_q    <= 1'b0;
    end else begin
      tstate_q <= tstate_d;

      // -------- Init capture --------
      if (init_i) begin
        sess_k1_q        <= k1_i;
        sess_k2_q        <= k2_i;
        sess_sector_be_q <= le_to_be(sector_i);
        sess_mode_q      <= mode_i;
        sess_total_q     <= total_bytes_i;
        blk_idx_q        <= 12'd0;
        cts_held_q       <= 128'd0;
        cts_partial_bc_q <= 5'd0;
        cts_t_prev_q     <= 128'd0;
        result_valid_q   <= 1'b0;
        result_last_q    <= 1'b0;
      end

      // -------- Capture T from tweak-key encrypt --------
      if (tstate_q == T_DERIVE_T && aes_valid_o) begin
        tweak_q <= aes_data_o;
      end

      // -------- Accept a data block (T_RX or T_CTS_HOLD) --------
      if ((tstate_q == T_RX || tstate_q == T_CTS_HOLD) && data_valid_i) begin
        data_buf_q      <= data_i;
        data_bc_q       <= data_byte_count_i;
        data_last_buf_q <= data_last_i;
        if (tstate_q == T_CTS_HOLD) begin
          cts_partial_bc_q <= data_byte_count_i;
        end
      end

      // -------- DECRYPT-CTS pre-step tweak before penultimate AES --------
      // On the cycle T_RX -> T_AES_FULL with the penultimate FULL block
      // of a CTS-decrypt sector, save current tweak (T_{m-1}) and
      // advance to T_m so AES_dec uses T_m.
      if (enter_aes_full_w && decrypt_cts_penult_w) begin
        cts_t_prev_q <= tweak_q;
        tweak_q      <= tweak_next;
      end

      // -------- T_AES_FULL completion --------
      if (tstate_q == T_AES_FULL && aes_valid_o) begin
        if (cts_needed_w && (blk_idx_q == full_blocks_w - 12'd1)) begin
          // Penultimate full block of CTS sector: HOLD the post-XOR
          // result. Do NOT emit yet.
          // Encrypt: held = AES_enc(k1, P_{m-1} XOR T_{m-1}) XOR T_{m-1}
          //                = C_{m-1}
          // Decrypt: held = AES_dec(k1, C_{m-1} XOR T_m) XOR T_m
          //                = PP   (intermediate; the spec calls this
          //                        the "decrypted intermediate" used
          //                        for stealing).
          cts_held_q     <= aes_post_xor_w;
          // For DECRYPT, also save T_m -> we need it for the partial
          // AES output XOR. Also restore tweak_q to T_{m-1} for the
          // next AES (T_CTS_AES uses T_{m-1}).
          // Actually per spec for DECRYPT: the partial-block AES_dec
          // uses T_{m-1}. Since we stored T_{m-1} in cts_t_prev_q
          // before pre-stepping, we restore it now. (For ENCRYPT we
          // simply step normally to T_m.)
          if (sess_mode_q == M_DECRYPT) begin
            // For decrypt CTS, we want the partial-block AES to see T_{m-1}.
            // But we ALSO need the held value (cts_held_q) to be the
            // "PP-with-T_m-residue" -- wait, the held value is post-XOR
            // with current tweak_q which is T_m. Good. Restore tweak_q
            // for the next AES pass.
            tweak_q <= cts_t_prev_q;       // T_{m-1}
          end else begin
            // Encrypt: advance tweak to T_m for the next AES (partial).
            tweak_q <= tweak_next;
          end
          blk_idx_q      <= blk_idx_q + 12'd1;
          result_valid_q <= 1'b0;          // suppress emit
        end else begin
          // Standard emit.
          result_q       <= aes_post_xor_w & be_byte_mask128(data_bc_q);
          result_bc_q    <= data_bc_q;
          result_last_q  <= data_last_buf_q && !cts_needed_w;
          result_valid_q <= 1'b1;
        end
      end

      // -------- Standard emit handshake clears valid + advances tweak --------
      if (tstate_q == T_OUT && result_valid_q && result_ready_i) begin
        result_valid_q <= 1'b0;
        // Advance tweak unless we already pre-stepped (CTS-decrypt
        // penultimate block does its own tweak handling above).
        tweak_q     <= tweak_next;
        blk_idx_q   <= blk_idx_q + 12'd1;
      end

      // -------- T_CTS_AES completion --------
      // The result of this AES is the FIRST CTS output block (16 bytes),
      // i.e. Cm in encrypt or Pm in decrypt. tweak_q at this point is:
      //   encrypt: T_m
      //   decrypt: T_{m-1}
      if (tstate_q == T_CTS_AES && aes_valid_o) begin
        result_q       <= aes_post_xor_w;
        result_bc_q    <= 5'd16;
        result_last_q  <= 1'b0;
        result_valid_q <= 1'b1;
      end

      // -------- After consumer takes the first CTS output, drop valid --------
      // We drop for one cycle and re-raise in T_CTS_EMIT_PARTIAL so the
      // assertion p_result_stable does not fire from result_o changing
      // while valid is still high.
      if (tstate_q == T_CTS_EMIT_FULL && result_valid_q && result_ready_i) begin
        result_valid_q <= 1'b0;
      end

      // -------- Stage the partial trailing output --------
      if (tstate_q == T_CTS_EMIT_PARTIAL && !result_valid_q) begin
        result_q       <= cts_held_q & be_byte_mask128(cts_partial_bc_q);
        result_bc_q    <= cts_partial_bc_q;
        result_last_q  <= 1'b1;
        result_valid_q <= 1'b1;
      end

      // -------- Final consume --------
      if (tstate_q == T_CTS_EMIT_PARTIAL && result_valid_q && result_ready_i) begin
        result_valid_q <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------
  // External handshake outputs
  // ------------------------------------------------------------------
  assign init_ready_o = (tstate_q == T_IDLE) || (tstate_q == T_DONE);
  assign data_ready_o = (tstate_q == T_RX) || (tstate_q == T_CTS_HOLD);

  assign result_valid_o      = result_valid_q;
  assign result_o            = result_q;
  assign result_byte_count_o = result_bc_q;
  assign result_last_o       = result_last_q;

endmodule
