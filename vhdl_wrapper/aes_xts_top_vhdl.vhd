-- SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
--
-- VHDL-2008 wrapper for the SystemVerilog aes_xts_top module.
--
-- This entity exposes the XTS core's port list in VHDL syntax. The
-- architecture instantiates the SystemVerilog module by component name;
-- mixed-language elaboration is supported natively by Vivado, Quartus,
-- ModelSim/Questa, and Aldec, and via the GHDL VHPI bridge for open
-- simulation.
--
-- Status: WRAPPER ONLY. The XTS datapath itself remains in SystemVerilog
-- (rtl/*.sv). A native VHDL port of the datapath is listed as future work.
--
-- I/O contract: identical to aes_xts_top.sv (see PORT_DESCRIPTION.md).
--   * Single clock, active-low synchronous reset.
--   * Two 128-bit keys (k1 = data, k2 = tweak), 128-bit sector number
--     in little-endian byte order.
--   * Streaming data interface (16-byte blocks, last may be 1..15 for CTS).
--   * Streaming result interface in lock-step.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity aes_xts_top_vhdl is
  port (
    clk_i               : in  std_logic;
    rst_ni              : in  std_logic;

    init_i              : in  std_logic;
    k1_i                : in  std_logic_vector(127 downto 0);
    k2_i                : in  std_logic_vector(127 downto 0);
    sector_i            : in  std_logic_vector(127 downto 0);
    mode_i              : in  std_logic;
    total_bytes_i       : in  std_logic_vector( 15 downto 0);
    init_ready_o        : out std_logic;

    data_valid_i        : in  std_logic;
    data_i              : in  std_logic_vector(127 downto 0);
    data_byte_count_i   : in  std_logic_vector(  4 downto 0);
    data_last_i         : in  std_logic;
    data_ready_o        : out std_logic;

    result_valid_o      : out std_logic;
    result_o            : out std_logic_vector(127 downto 0);
    result_byte_count_o : out std_logic_vector(  4 downto 0);
    result_last_o       : out std_logic;
    result_ready_i      : in  std_logic
  );
end entity aes_xts_top_vhdl;

architecture rtl of aes_xts_top_vhdl is

  component aes_xts_top
    port (
      clk_i               : in  std_logic;
      rst_ni              : in  std_logic;
      init_i              : in  std_logic;
      k1_i                : in  std_logic_vector(127 downto 0);
      k2_i                : in  std_logic_vector(127 downto 0);
      sector_i            : in  std_logic_vector(127 downto 0);
      mode_i              : in  std_logic;
      total_bytes_i       : in  std_logic_vector( 15 downto 0);
      init_ready_o        : out std_logic;
      data_valid_i        : in  std_logic;
      data_i              : in  std_logic_vector(127 downto 0);
      data_byte_count_i   : in  std_logic_vector(  4 downto 0);
      data_last_i         : in  std_logic;
      data_ready_o        : out std_logic;
      result_valid_o      : out std_logic;
      result_o            : out std_logic_vector(127 downto 0);
      result_byte_count_o : out std_logic_vector(  4 downto 0);
      result_last_o       : out std_logic;
      result_ready_i      : in  std_logic
    );
  end component;

begin

  u_xts : aes_xts_top
    port map (
      clk_i               => clk_i,
      rst_ni              => rst_ni,
      init_i              => init_i,
      k1_i                => k1_i,
      k2_i                => k2_i,
      sector_i            => sector_i,
      mode_i              => mode_i,
      total_bytes_i       => total_bytes_i,
      init_ready_o        => init_ready_o,
      data_valid_i        => data_valid_i,
      data_i              => data_i,
      data_byte_count_i   => data_byte_count_i,
      data_last_i         => data_last_i,
      data_ready_o        => data_ready_o,
      result_valid_o      => result_valid_o,
      result_o            => result_o,
      result_byte_count_o => result_byte_count_o,
      result_last_o       => result_last_o,
      result_ready_i      => result_ready_i
    );

end architecture rtl;
