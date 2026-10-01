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

.PHONY: all sim tests run-tests clean
all: sim

# ---------------------------------------------------------------- simulator
SIM_CORE := $(BUILD)/sim_core/Vrv_core
sim: $(SIM_CORE)
$(SIM_CORE): $(RTL_CORE) sim/tb_core.cpp
	verilator --cc --exe --build -j 8 $(VFLAGS) --top-module rv_core \
	  -Mdir $(BUILD)/sim_core $(RTL_CORE) sim/tb_core.cpp -o Vrv_core

# ---------------------------------------------------------------- riscv-tests
include sw/riscv-tests.mk

clean:
	rm -rf $(BUILD)
