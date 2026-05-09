// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// AES-128 iterative core (FIPS-197).
//
// Architecture: 1 round per cycle, shared encrypt/decrypt datapath.
// Latency: ~12 cycles per block (1 cycle to register inputs + key, 11 round cycles,
//          output asserted on the cycle after the last round).
// Resources: ~1.5k LUTs on iCE40, ~1k on Artix-7 (estimate; final synth varies).
//
// Handshake:
//   * Master presents key_i, data_i, encrypt_i and asserts valid_i.
//   * Core captures when (valid_i && ready_o), drops ready_o, runs rounds.
//   * When done, core asserts valid_o; data_o holds ciphertext/plaintext.
//   * Master asserts ready_i to consume; core then re-asserts ready_o.
//
// Reset: rst_ni is active-low synchronous (sampled on rising clk_i edge).

module aes_core (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [127:0] key_i,
  input  logic [127:0] data_i,
  input  logic         encrypt_i,
  input  logic         valid_i,
  output logic         ready_o,
  output logic [127:0] data_o,
  output logic         valid_o,
  input  logic         ready_i
);

  // ---------- Round constants (FIPS-197 Appendix A) -------------------------
  // rcon[1..10] per FIPS-197 (index 0 unused)
  function automatic logic [7:0] rcon (input logic [3:0] r);
    case (r)
      4'd1:  rcon = 8'h01;
      4'd2:  rcon = 8'h02;
      4'd3:  rcon = 8'h04;
      4'd4:  rcon = 8'h08;
      4'd5:  rcon = 8'h10;
      4'd6:  rcon = 8'h20;
      4'd7:  rcon = 8'h40;
      4'd8:  rcon = 8'h80;
      4'd9:  rcon = 8'h1b;
      4'd10: rcon = 8'h36;
      default: rcon = 8'h00;
    endcase
  endfunction

  // ---------- FSM -----------------------------------------------------------
  typedef enum logic [1:0] {
    S_IDLE   = 2'd0,
    S_EXPAND = 2'd1,  // expanding round-key schedule (10 cycles)
    S_RUN    = 2'd2,  // running cipher rounds (10 cycles after initial AddRoundKey)
    S_DONE   = 2'd3
  } state_e;

  state_e state_q, state_d;
  logic [3:0] round_q, round_d;     // 0..10
  logic       encrypt_q;
  logic [127:0] state_reg_q, state_reg_d;
  logic [127:0] data_out_q, data_out_d;

  // Round-key storage: 11 keys x 128 bits.
  logic [127:0] rk_q [0:10];
  logic [127:0] rk_d [0:10];

  // ---------- Key expansion combinational --------------------------------------
  // The new round key for round (round_q + 1) given rk_q[round_q].
  logic [127:0] next_rk;
  aes_key_expand u_kx (
    .round_key_i (rk_q[round_q]),
    .rcon_i      (rcon(round_q + 4'd1)),
    .round_key_o (next_rk)
  );

  // ---------- Round combinational ------------------------------------------
  // For encrypt: round_q = number of completed rounds. Apply round (round_q+1) using rk_q[round_q+1].
  // final_round when (round_q + 1) == 10.
  // For decrypt: we apply rounds in reverse. round_q counts rounds completed (0..10).
  //   First step (round_q == 0) does AddRoundKey only with rk_q[10] -- handled at S_RUN start.
  //   Then for round_q = 1..9 apply inverse-round (non-final) with rk_q[10 - round_q].
  //   For round_q = 10 the cycle producing it: apply inverse-round (final) with rk_q[0].
  //
  // To unify, in S_RUN we always feed an aes_round in either direction with a selected
  // round key and a final_round flag.

  logic [127:0] round_in;
  logic [127:0] round_out;
  logic [127:0] selected_rk;
  logic         is_final;

  assign round_in = state_reg_q;

  // Selection of round key & final flag
  always_comb begin
    if (encrypt_q) begin
      // applying round (round_q + 1)
      selected_rk = rk_q[round_q + 4'd1];
      is_final    = (round_q == 4'd9); // about to do round 10
    end else begin
      // decrypt: applying round (round_q + 1) in inverse direction.
      // First inverse round uses rk_q[9], last inverse round uses rk_q[0].
      // Map: at round_q == k (k = 0..9), use rk_q[9-k]. final when k==9.
      selected_rk = rk_q[4'd9 - round_q];
      is_final    = (round_q == 4'd9);
    end
  end

  aes_round u_rnd (
    .state_i       (round_in),
    .round_key_i   (selected_rk),
    .encrypt_i     (encrypt_q),
    .final_round_i (is_final),
    .state_o       (round_out)
  );

  // ---------- Outputs --------------------------------------------------------
  assign data_o  = data_out_q;
  assign valid_o = (state_q == S_DONE);
  assign ready_o = (state_q == S_IDLE);

  // ---------- FSM next-state -------------------------------------------------
  always_comb begin
    state_d     = state_q;
    round_d     = round_q;
    state_reg_d = state_reg_q;
    data_out_d  = data_out_q;
    for (int i = 0; i < 11; i++) rk_d[i] = rk_q[i];

    unique case (state_q)
      S_IDLE: begin
        if (valid_i) begin
          // Capture key (rk[0]) and data; pre-AddRoundKey.
          rk_d[0] = key_i;
          for (int i = 1; i < 11; i++) rk_d[i] = '0;
          if (encrypt_i) begin
            // initial AddRoundKey with rk[0]
            state_reg_d = data_i ^ key_i;
          end else begin
            // for decrypt, we need rk[10] applied first; load data and defer until expand done
            state_reg_d = data_i;
          end
          round_d = 4'd0;
          state_d = S_EXPAND;
        end
      end

      S_EXPAND: begin
        // Compute rk_d[round_q + 1] from rk_q[round_q].
        rk_d[round_q + 4'd1] = next_rk;
        if (round_q == 4'd9) begin
          // After this cycle, all rk_q[0..10] valid.
          // For decrypt: we must do initial AddRoundKey using rk[10]. Since we computed it
          // this cycle into rk_d[10] but it won't be in rk_q until next clock, use next_rk directly.
          if (!encrypt_q) begin
            state_reg_d = state_reg_q ^ next_rk; // initial AddRoundKey for decrypt
          end
          round_d = 4'd0;
          state_d = S_RUN;
        end else begin
          round_d = round_q + 4'd1;
        end
      end

      S_RUN: begin
        // Apply round; advance state. We use selected_rk via the round-instance above.
        state_reg_d = round_out;
        if (round_q == 4'd9) begin
          // Just executed final round.
          data_out_d = round_out;
          round_d = 4'd0;
          state_d = S_DONE;
        end else begin
          round_d = round_q + 4'd1;
        end
      end

      S_DONE: begin
        if (ready_i) begin
          state_d = S_IDLE;
        end
      end

      default: state_d = S_IDLE;
    endcase
  end

  // ---------- Sequential -----------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q     <= S_IDLE;
      round_q     <= 4'd0;
      encrypt_q   <= 1'b0;
      state_reg_q <= '0;
      data_out_q  <= '0;
      for (int i = 0; i < 11; i++) rk_q[i] <= '0;
    end else begin
      state_q     <= state_d;
      round_q     <= round_d;
      state_reg_q <= state_reg_d;
      data_out_q  <= data_out_d;
      for (int i = 0; i < 11; i++) rk_q[i] <= rk_d[i];
      if (state_q == S_IDLE && valid_i) encrypt_q <= encrypt_i;
    end
  end

endmodule
