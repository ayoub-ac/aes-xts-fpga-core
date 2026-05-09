# VHDL wrapper

`aes_xts_top_vhdl.vhd` is a thin VHDL-2008 entity that re-exposes the
SystemVerilog `aes_xts_top` module under a VHDL-friendly interface. Use
it from a VHDL design that does not want to touch SystemVerilog directly.

## Status

**Wrapper only.** The AES-128 cipher, GF(2^128) alpha-multiplier, and
XTS state machine all live in `rtl/*.sv` and are instantiated as a
SystemVerilog black-box. Mixed-language elaboration is supported by
every commercial simulator and synthesiser the core has been tested
against.

A pure VHDL re-implementation of the datapath is on the roadmap (Premium
tier, scope: parity with `rtl/aes_xts_top.sv` including the same
testbench checks). Until then, treat this directory as a binding layer,
not as a second implementation.

## Usage

### Vivado / Quartus / Diamond

Add both the SystemVerilog files and `aes_xts_top_vhdl.vhd` to the same
project library (`work` is fine). The toolchain resolves the SV
component automatically:

```tcl
# Vivado
read_verilog -sv {rtl/aes_sbox.sv rtl/aes_inv_sbox.sv rtl/aes_key_expand.sv \
                   rtl/aes_round.sv rtl/aes_core.sv rtl/gf128_mul_alpha.sv \
                   rtl/aes_xts_top.sv}
read_vhdl -vhdl2008 vhdl_wrapper/aes_xts_top_vhdl.vhd
```

### ModelSim / Questa / Aldec

```
vlog -sv rtl/aes_sbox.sv rtl/aes_inv_sbox.sv rtl/aes_key_expand.sv \
        rtl/aes_round.sv rtl/aes_core.sv rtl/gf128_mul_alpha.sv \
        rtl/aes_xts_top.sv
vcom -2008 vhdl_wrapper/aes_xts_top_vhdl.vhd
```

### GHDL + Verilator (open-source co-sim)

GHDL compiles the VHDL side, Verilator compiles the SV side, and the two
are linked through GHDL's VHPI bridge. The provided `make vhdl-test`
target wraps this; run it from the repository root:

```
make vhdl-test
```

The target is a no-op (with a notice) if `ghdl` is not on `$PATH`.

## Instantiation example

```vhdl
library ieee;
  use ieee.std_logic_1164.all;

entity my_design is end entity;
architecture rtl of my_design is
  signal clk, rstn                            : std_logic;
  signal init, init_ready                     : std_logic;
  signal k1, k2                               : std_logic_vector(127 downto 0);
  signal sector                               : std_logic_vector(127 downto 0);
  signal mode                                 : std_logic;
  signal total_bytes                          : std_logic_vector( 15 downto 0);
  signal data_valid, data_ready, data_last    : std_logic;
  signal data_in                              : std_logic_vector(127 downto 0);
  signal data_bc                              : std_logic_vector(  4 downto 0);
  signal result_valid, result_ready, result_last : std_logic;
  signal result_out                           : std_logic_vector(127 downto 0);
  signal result_bc                            : std_logic_vector(  4 downto 0);
begin
  u_xts : entity work.aes_xts_top_vhdl
    port map (
      clk_i               => clk,
      rst_ni              => rstn,
      init_i              => init,
      k1_i                => k1,
      k2_i                => k2,
      sector_i            => sector,
      mode_i              => mode,
      total_bytes_i       => total_bytes,
      init_ready_o        => init_ready,
      data_valid_i        => data_valid,
      data_i              => data_in,
      data_byte_count_i   => data_bc,
      data_last_i         => data_last,
      data_ready_o        => data_ready,
      result_valid_o      => result_valid,
      result_o            => result_out,
      result_byte_count_o => result_bc,
      result_last_o       => result_last,
      result_ready_i      => result_ready
    );
end architecture;
```

## What this wrapper does NOT change

* Latency, throughput, area: identical to `aes_xts_top.sv`. There is no
  additional pipeline stage. Per sector: 12 cycles for T-derivation
  (`AES_enc(k2, sector)`), then 12 cycles per 16-byte data block, plus
  the small CTS overhead (one extra AES + emit) for non-aligned sectors.
* Endianness: byte 0 of every byte-stream message lives at bits
  `[127:120]` of the wide bus. The sector number `sector_i` is encoded
  little-endian (byte 0 in `[7:0]`) per IEEE Std 1619-2018. That matches
  Python `cryptography.hazmat.primitives.ciphers.modes.XTS` and
  OpenSSL's on-the-wire convention.
* Reset polarity: still active-low synchronous (`rst_ni`).
