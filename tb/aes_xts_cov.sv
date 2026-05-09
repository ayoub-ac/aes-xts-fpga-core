// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Functional coverage collector for aes_xts_top. Sticky bins recorded
// across the regression so the harness can print a single coverage line
// at end-of-test.
//
// Bins (10 total):
//   c_mode_encrypt        : init seen with mode_i = 0 (encrypt)
//   c_mode_decrypt        : init seen with mode_i = 1 (decrypt)
//   c_single_block        : a session with total_bytes_i == 16
//   c_multi_block         : a session with total_bytes_i > 16 and aligned
//   c_cts_session         : a session whose total_bytes is not multiple of 16
//   c_sector_boundary_4kb : a session of exactly 4096 bytes (real-world FDE)
//   c_back_to_back        : a new init pulse within <= 4 cycles of prior
//                           result_last
//   c_idle_seen           : at least one cycle of !init_i and !data_valid_i
//                           between sessions (not currently mid-stream)
//   c_partial_last        : data_last_i with byte_count < 16 (CTS partial)
//   c_full_last           : data_last_i with byte_count == 16 (aligned)

module aes_xts_cov (
  input logic         clk_i,
  input logic         rst_ni,
  input logic         init_i,
  input logic         mode_i,
  input logic [15:0]  total_bytes_i,
  input logic         data_valid_i,
  input logic         data_ready_o,
  input logic         data_last_i,
  input logic [4:0]   data_byte_count_i,
  input logic         result_valid_o,
  input logic         result_last_o
);

  logic c_mode_encrypt        /*verilator public*/;
  logic c_mode_decrypt        /*verilator public*/;
  logic c_single_block        /*verilator public*/;
  logic c_multi_block         /*verilator public*/;
  logic c_cts_session         /*verilator public*/;
  logic c_sector_boundary_4kb /*verilator public*/;
  logic c_back_to_back        /*verilator public*/;
  logic c_idle_seen           /*verilator public*/;
  logic c_partial_last        /*verilator public*/;
  logic c_full_last           /*verilator public*/;

  logic [7:0] cycles_since_last_q;
  logic       saw_last_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      cycles_since_last_q <= 8'd0;
      saw_last_q          <= 1'b0;
    end else begin
      if (init_i) begin
        if (mode_i == 1'b0) c_mode_encrypt <= 1'b1;
        else                c_mode_decrypt <= 1'b1;
        if (total_bytes_i == 16'd16)                    c_single_block <= 1'b1;
        if (total_bytes_i  > 16'd16 &&
            total_bytes_i[3:0] == 4'd0)                 c_multi_block  <= 1'b1;
        if (total_bytes_i[3:0] != 4'd0)                 c_cts_session  <= 1'b1;
        if (total_bytes_i == 16'd4096)                  c_sector_boundary_4kb <= 1'b1;
        if (saw_last_q && cycles_since_last_q <= 8'd4)  c_back_to_back <= 1'b1;
        saw_last_q          <= 1'b0;
        cycles_since_last_q <= 8'd0;
      end else if (saw_last_q) begin
        if (cycles_since_last_q != 8'hff)
          cycles_since_last_q <= cycles_since_last_q + 8'd1;
      end

      if (result_valid_o && result_last_o) saw_last_q <= 1'b1;

      if (data_valid_i && data_ready_o && data_last_i) begin
        if (data_byte_count_i == 5'd16) c_full_last    <= 1'b1;
        else                            c_partial_last <= 1'b1;
      end

      // Idle = saw_last_q true (between sessions) and no new init.
      if (saw_last_q && !init_i && !data_valid_i) c_idle_seen <= 1'b1;
    end
  end

  initial begin
    c_mode_encrypt        = 1'b0;
    c_mode_decrypt        = 1'b0;
    c_single_block        = 1'b0;
    c_multi_block         = 1'b0;
    c_cts_session         = 1'b0;
    c_sector_boundary_4kb = 1'b0;
    c_back_to_back        = 1'b0;
    c_idle_seen           = 1'b0;
    c_partial_last        = 1'b0;
    c_full_last           = 1'b0;
  end

endmodule
