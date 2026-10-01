# FPGA implementation for the ULX3S (ECP5 LFE5U-85F, CABGA381)
#   make -C synth          synthesize + place & route + timing report
#   make -C synth area     per-block utilization (core / caches / SoC)
ROOT   := $(abspath ..)
BUILD  := $(ROOT)/build/synth
RTL    := $(wildcard $(ROOT)/rtl/core/*.v) $(wildcard $(ROOT)/rtl/cache/*.v) $(wildcard $(ROOT)/rtl/soc/*.v)
FREQ   ?= 25

all: $(BUILD)/top.config

$(BUILD)/firmware.hex: $(ROOT)/build/sw/hello.elf
	@mkdir -p $(BUILD); python3 $(ROOT)/scripts/elf2hex.py $< $@

$(BUILD)/top.json: $(RTL) top_ulx3s.v $(BUILD)/firmware.hex
	cd $(BUILD) && yosys -q -l synth.log -p "read_verilog -I$(ROOT)/rtl/core $(RTL) $(CURDIR)/top_ulx3s.v; \
	  synth_ecp5 -top top_ulx3s -abc9 -json top.json; tee -o utilization.txt stat"

$(BUILD)/top.config: $(BUILD)/top.json ulx3s.lpf
	cd $(BUILD) && nextpnr-ecp5 --85k --package CABGA381 --json top.json --lpf $(CURDIR)/ulx3s.lpf \
	  --freq $(FREQ) --textcfg top.config --report pnr_report.json --timing-allow-fail -l pnr.log 2>&1 | tail -3
	@grep -E "Max frequency|Device utilisation" -A12 $(BUILD)/pnr.log | grep -E "MHz|TRELLIS_COMB|TRELLIS_FF|DP16KD|MULT18|TRELLIS_RAMW" | head -12

bitstream: $(BUILD)/top.config
	ecppack $(BUILD)/top.config $(BUILD)/top.bit

# Per-module area breakdown (generic synthesis to ECP5 cells, hierarchy kept)
area: $(RTL)
	@mkdir -p $(BUILD)
	cd $(BUILD) && yosys -q -l area.log -p "read_verilog -I$(ROOT)/rtl/core $(RTL); \
	  synth_ecp5 -top rv_soc -noflatten; tee -o area.txt stat"
	@grep -E "^=== |TRELLIS_COMB|TRELLIS_FF|DP16KD|MULT18X18D|TRELLIS_RAMW|Number of cells" $(BUILD)/area.txt | head -80
