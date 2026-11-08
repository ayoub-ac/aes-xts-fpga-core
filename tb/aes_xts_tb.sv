// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// Top-level testbench wrapper for aes_xts_top.
// Stimulus from tb/sim_main.cpp.

module aes_xts_tb (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  logic         init_i,
  input  logic [127:0] k1_i,
  input  logic [127:0] k2_i,
  input  logic [127:0] sector_i,
  input  logic         mode_i,
  input  logic [15:0]  total_bytes_i,
  output logic         init_ready_o,

  input  logic         data_valid_i,
  input  logic [127:0] data_i,
  input  logic [4:0]   data_byte_count_i,
  input  logic         data_last_i,
  output logic         data_ready_o,

  output logic         result_valid_o,
  output logic [127:0] result_o,
  output logic [4:0]   result_byte_count_o,
  output logic         result_last_o,
  input  logic         result_ready_i
);

  aes_xts_top u_dut (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .init_i             (init_i),
    .k1_i               (k1_i),
    .k2_i               (k2_i),
    .sector_i           (sector_i),
    .mode_i             (mode_i),
    .total_bytes_i      (total_bytes_i),
    .init_ready_o       (init_ready_o),
    .data_valid_i       (data_valid_i),
    .data_i             (data_i),
    .data_byte_count_i  (data_byte_count_i),
    .data_last_i        (data_last_i),
    .data_ready_o       (data_ready_o),
    .result_valid_o     (result_valid_o),
    .result_o           (result_o),
    .result_byte_count_o(result_byte_count_o),
    .result_last_o      (result_last_o),
    .result_ready_i     (result_ready_i)
  );

  // ----------------------------------------------------------------
  // Bind the SVA + coverage modules.
  // ----------------------------------------------------------------
  aes_xts_assertions u_assert (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .init_i        (init_i),
    .data_valid_i  (data_valid_i),
    .data_ready_o  (data_ready_o),
    .data_last_i   (data_last_i),
    .result_valid_o(result_valid_o),
    .result_o      (result_o),
    .result_last_o (result_last_o),
    .init_ready_o  (init_ready_o)
  );

  aes_xts_cov u_cov (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .init_i            (init_i),
    .mode_i            (mode_i),
    .total_bytes_i     (total_bytes_i),
    .data_valid_i      (data_valid_i),
    .data_ready_o      (data_ready_o),
    .data_last_i       (data_last_i),
    .data_byte_count_i (data_byte_count_i),
    .result_valid_o    (result_valid_o),
    .result_last_o     (result_last_o)
  );

endmodule
