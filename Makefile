# Top-level Makefile.  `source env.sh` first (puts tools on PATH).
ROOT      := $(abspath .)
BUILD     := $(ROOT)/build
RTL_CORE  := $(wildcard rtl/core/*.v)
VFLAGS    := -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
             --x-assign unique --x-initial unique -O3 -Irtl/core
TRACE     ?= 0
ifeq ($(TRACE),1)
VFLAGS    += --trace-fst -CFLAGS -DVM_TRACE=1
endif

.PHONY: all sim sim-soc tests tests-soc run-tests run-tests-soc clean
all: sim

# ---------------------------------------------------------------- simulator
SIM_CORE := $(BUILD)/sim_core/Vrv_core
sim: $(SIM_CORE)
$(SIM_CORE): $(RTL_CORE) sim/tb_core.cpp
	verilator --cc --exe --build -j 8 $(VFLAGS) --top-module rv_core \
	  -Mdir $(BUILD)/sim_core $(RTL_CORE) sim/tb_core.cpp -o Vrv_core

clean:
	rm -rf $(BUILD)

# ---------------------------------------------------------------- SoC simulator
RTL_SOC  := $(RTL_CORE) $(wildcard rtl/cache/*.v) $(wildcard rtl/soc/*.v)
SOC_DEFS ?=
SIM_SOC  := $(BUILD)/sim_soc$(SOC_TAG)/Vrv_soc
sim-soc: $(SIM_SOC)
$(SIM_SOC): $(RTL_SOC) sim/tb_soc.cpp
	verilator --cc --exe --build -j 8 $(VFLAGS) $(SOC_DEFS) --top-module rv_soc \
	  -Mdir $(dir $(SIM_SOC)) $(RTL_SOC) sim/tb_soc.cpp -o Vrv_soc

# ---------------------------------------------------------------- riscv-tests
include sw/riscv-tests.mk

# ---------------------------------------------------------------- verification
.PHONY: unit random random-soc regress
unit:
	cd verif/cocotb && python3 -m pytest test_units.py -q
random: $(SIM_CORE)
	verif/rig/run_random.sh 1 $(or $(N),100)
random-soc:
	$(MAKE) sim-soc SOC_TAG=_stress SOC_DEFS="-GRAM_LATENCY=6 -GCACHE_SET_BITS=2"
	MODE=soc SIM=$(BUILD)/sim_soc_stress/Vrv_soc OUT=$(BUILD)/random_soc verif/rig/run_random.sh 1 $(or $(N),50)
regress: run-tests run-tests-soc unit random random-soc
