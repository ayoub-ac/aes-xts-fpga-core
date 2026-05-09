# AES-XTS-128 FPGA core - build / lint / sim / synth
#
# Targets:
#   make lint            verilator --lint-only on RTL (sbox + round + key
#                        expand + core + gf128 alpha multiplier + xts top)
#   make sim             build the XTS top-level simulator
#   make test            build + run XTS sim, check for "+PASS"
#   make synth           Yosys: ice40 + ecp5 + xilinx generic for the XTS top
#   make synth_report    run all available toolchains and emit SYNTH_REPORT.md
#   make vhdl-test       GHDL+Verilator co-sim of the VHDL wrapper (if installed)
#   make clean           remove build artifacts
#   make regen_vectors   regenerate tb/random_vectors.h from cryptography

VERILATOR ?= verilator
YOSYS     ?= yosys
GHDL      ?= ghdl
VIVADO    ?= vivado
QUARTUS   ?= quartus_sh

RTL_AES := \
    rtl/aes_sbox.sv \
    rtl/aes_inv_sbox.sv \
    rtl/aes_key_expand.sv \
    rtl/aes_round.sv \
    rtl/aes_core.sv

RTL_XTS := \
    $(RTL_AES) \
    rtl/gf128_mul_alpha.sv \
    rtl/aes_xts_top.sv

TB_TOP := tb/aes_xts_tb.sv
TB_AUX := tb/aes_xts_assertions.sv tb/aes_xts_cov.sv
TB_CPP := tb/sim_main.cpp

VFLAGS := -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL

.PHONY: lint sim test synth synth_report vhdl-test clean regen_vectors

lint:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module aes_xts_tb \
	    $(RTL_XTS) $(TB_TOP) $(TB_AUX)

sim: obj_dir/Vaes_xts_tb

obj_dir/Vaes_xts_tb: $(RTL_XTS) $(TB_TOP) $(TB_AUX) $(TB_CPP) \
                     tb/random_vectors.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) --assert --public-flat-rw \
	    --top-module aes_xts_tb \
	    $(RTL_XTS) $(TB_TOP) $(TB_AUX) $(TB_CPP) \
	    -o Vaes_xts_tb

test: sim
	./obj_dir/Vaes_xts_tb | tee test.log
	@grep -q "+PASS" test.log && echo "TESTS PASSED" || (echo "TESTS FAILED" && exit 1)

# ---------- Open synthesis (Yosys) ------------------------------------------
synth:
	$(YOSYS) -p "read_verilog -sv $(RTL_XTS); hierarchy -top aes_xts_top; synth_ice40 -top aes_xts_top; stat" \
	    | tee synth_ice40.log
	$(YOSYS) -p "read_verilog -sv $(RTL_XTS); hierarchy -top aes_xts_top; synth_ecp5 -top aes_xts_top -abc9; stat" \
	    | tee synth_ecp5.log
	$(YOSYS) -p "read_verilog -sv $(RTL_XTS); hierarchy -top aes_xts_top; synth_xilinx -top aes_xts_top; stat" \
	    | tee synth_xilinx.log

# ---------- Cross-toolchain synthesis report --------------------------------
synth_report:
	@bash scripts/synth_report.sh

# ---------- VHDL co-sim (optional) ------------------------------------------
vhdl-test:
	@which $(GHDL) >/dev/null 2>&1 || { echo "ghdl not installed - skipping vhdl-test"; exit 0; }
	@which $(VERILATOR) >/dev/null 2>&1 || { echo "verilator not installed"; exit 1; }
	@bash scripts/vhdl_cosim.sh

clean:
	rm -rf obj_dir \
	    test.log \
	    synth_ice40.log synth_ecp5.log synth_xilinx.log \
	    synth_report/ SYNTH_REPORT.md

regen_vectors:
	python3 tb/gen_random_vectors.py > tb/random_vectors.h
