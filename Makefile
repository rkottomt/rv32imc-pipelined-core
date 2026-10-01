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
.PHONY: unit random random-soc regress directed
# directed tests (C / asm in sw/tests): run on core (with ISS co-sim) and SoC
directed: $(SIM_CORE) $(SIM_SOC)
	$(MAKE) -C sw tests
	@for e in $(BUILD)/sw/hello.elf $(BUILD)/sw/bp_fixup.elf $(BUILD)/sw/irq_test.elf; do \
	  $(SIM_CORE) +elf=$$e +trace=$$e.trace > /dev/null && python3 verif/iss/compare.py $$e $$e.trace --quiet && \
	  $(SIM_SOC) +elf=$$e > /dev/null && echo "PASS $$(basename $$e)" || { echo "FAIL $$(basename $$e)"; exit 1; }; done
unit:
	cd verif/cocotb && python3 -m pytest test_units.py -q
random: $(SIM_CORE)
	verif/rig/run_random.sh 1 $(or $(N),100)
random-soc:
	$(MAKE) sim-soc SOC_TAG=_stress SOC_DEFS="-GRAM_LATENCY=6 -GCACHE_SET_BITS=2"
	MODE=soc SIM=$(BUILD)/sim_soc_stress/Vrv_soc OUT=$(BUILD)/random_soc verif/rig/run_random.sh 1 $(or $(N),50)
regress: run-tests run-tests-soc directed unit random random-soc

# ---------------------------------------------------------------- code coverage
# Line + toggle coverage of the core from riscv-tests + random programs.
SIM_COV := $(BUILD)/sim_cov/Vrv_core
$(SIM_COV): $(RTL_CORE) sim/tb_core.cpp
	verilator --cc --exe --build -j 8 $(VFLAGS) --coverage-line --coverage-toggle --top-module rv_core \
	  -Mdir $(BUILD)/sim_cov $(RTL_CORE) sim/tb_core.cpp -o Vrv_core
code-coverage: $(SIM_COV) tests
	rm -rf $(BUILD)/cov && mkdir -p $(BUILD)/cov
	i=0; for t in $(RT_ELFS); do i=$$((i+1)); \
	  $(SIM_COV) +elf=$$t +cov=$(BUILD)/cov/rt$$i.dat > /dev/null || true; done
	for s in $$(seq 1 40); do \
	  [ -f $(BUILD)/random/r$$s.elf ] || python3 verif/rig/rig.py --seed $$s --length 3000 $$( [ $$((s%2)) = 1 ] && echo --irq) -o $(BUILD)/random/r$$s.S && \
	  riscv-none-elf-gcc -march=rv32imc_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles -Wl,--no-warn-rwx-segments \
	    -T sw/link.ld $(BUILD)/random/r$$s.S -o $(BUILD)/random/r$$s.elf; \
	  $(SIM_COV) +elf=$(BUILD)/random/r$$s.elf +seed=$$s +stall=$$((s*7%50)) +dlat=$$((s%4+1)) +ilat=$$((s%3+1)) \
	    $$( [ $$((s%2)) = 1 ] && echo +irq_rand=2) +cov=$(BUILD)/cov/rnd$$s.dat > /dev/null || echo "seed $$s failed"; done
	$(MAKE) -C sw tests
	for t in bp_fixup irq_test; do $(SIM_COV) +elf=$(BUILD)/sw/$$t.elf +cov=$(BUILD)/cov/dir_$$t.dat > /dev/null || echo "$$t failed"; done
	verilator_coverage --write $(BUILD)/cov/merged.dat $(BUILD)/cov/*.dat
	verilator_coverage --annotate $(BUILD)/cov/annotated --annotate-min 1 $(BUILD)/cov/merged.dat | tail -3
