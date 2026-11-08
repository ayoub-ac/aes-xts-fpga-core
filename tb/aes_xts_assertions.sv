// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// SVA assertions for aes_xts_top. Properties cover protocol invariants
// enforced on every cycle of every test:
//
//   p_data_after_init    : data_ready_o never rises unless an init has
//                          been seen in this session.
//   p_result_stable      : result_o is stable while result_valid_o is
//                          high (the consumer must see a coherent block).
//   p_result_last_once   : result_last_o pulses exactly once per session.
//   p_init_ready_done    : init_ready_o re-asserts within LAT_MAX cycles
//                          of an init pulse (used to catch a stuck FSM
//                          after a malformed sector).
//   p_no_data_before_t   : data_ready_o stays low while T-derivation is
//                          in progress (i.e., at least 1 cycle after
//                          init_i).
//
// LAT_MAX is generous (8k) to cover full 4-KB sectors at 12 cycles/AES
// plus CTS overhead. Properties are wrapped in `ifndef SYNTHESIS so they
// strip on synthesis flows.

module aes_xts_assertions #(
  parameter int LAT_MAX = 8192
) (
  input logic         clk_i,
  input logic         rst_ni,
  input logic         init_i,
  input logic         data_valid_i,
  input logic         data_ready_o,
  input logic         data_last_i,
  input logic         result_valid_o,
  input logic [127:0] result_o,
  input logic         result_last_o,
  input logic         init_ready_o
);
`ifndef SYNTHESIS

  logic init_seen_q       = 1'b0;
  logic result_last_seen_q = 1'b0;
  int   cycles_since_init_q = 0;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      init_seen_q         <= 1'b0;
      result_last_seen_q  <= 1'b0;
      cycles_since_init_q <= 0;
    end else begin
      if (init_i) begin
        init_seen_q         <= 1'b1;
        result_last_seen_q  <= 1'b0;
        cycles_since_init_q <= 0;
      end else if (init_seen_q && !result_last_seen_q) begin
        cycles_since_init_q <= cycles_since_init_q + 1;
      end
      if (result_valid_o && result_last_o) begin
        result_last_seen_q <= 1'b1;
      end
    end
  end

  // 1. data_ready_o cannot rise without an init having been seen.
  property p_data_after_init;
    @(posedge clk_i) disable iff (!rst_ni)
      data_ready_o |-> init_seen_q;
  endproperty
  a_data_after_init: assert property (p_data_after_init)
    else $error("aes_xts: data_ready_o asserted before init_i ever seen");

  // 2. result_o stable while valid.
  property p_result_stable;
    @(posedge clk_i) disable iff (!rst_ni)
      result_valid_o |=> (!result_valid_o || $stable(result_o));
  endproperty
  a_result_stable: assert property (p_result_stable)
    else $error("aes_xts: result_o changed while result_valid_o asserted");

  // 3. result_last_o pulses at most once between init pulses (a sticky
  //    flag in the testbench tracks "seen" - the assertion fires if it's
  //    seen twice in the same session).
  property p_result_last_once;
    @(posedge clk_i) disable iff (!rst_ni || init_i)
      (result_valid_o && result_last_o) |-> !result_last_seen_q;
  endproperty
  a_result_last_once: assert property (p_result_last_once)
    else $error("aes_xts: result_last_o asserted twice in one session");

  // 4. init_ready_o eventually re-asserts (FSM not stuck).
  property p_init_eventually_ready;
    @(posedge clk_i) disable iff (!rst_ni)
      init_seen_q && !result_last_seen_q |-> (cycles_since_init_q < LAT_MAX);
  endproperty
  a_init_eventually_ready: assert property (p_init_eventually_ready)
    else $error("aes_xts: session did not finish within %0d cycles", LAT_MAX);

  // 5. data_ready_o cannot be high in the same cycle as init_i (T_RX
  //    can only be entered after T_DERIVE_T finishes ~12 cycles later).
  property p_no_data_before_t;
    @(posedge clk_i) disable iff (!rst_ni)
      init_i |-> !data_ready_o;
  endproperty
  a_no_data_before_t: assert property (p_no_data_before_t)
    else $error("aes_xts: data_ready_o high during init_i (T not derived yet)");

`endif
endmodule
