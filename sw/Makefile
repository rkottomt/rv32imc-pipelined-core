# Build C programs for the SoC.   make -C sw [coremark|dhrystone|tests]
CC      := riscv-none-elf-gcc
ARCH    ?= rv32imc_zicsr
CFLAGS  := -march=$(ARCH) -mabi=ilp32 -O2 -g -ffunction-sections -fdata-sections -Icommon
LDFLAGS := -march=$(ARCH) -mabi=ilp32 -nostartfiles -T soc.ld -Wl,--gc-sections -Wl,--no-warn-rwx-segments --specs=nano.specs
OUT     := ../build/sw
COMMON  := common/crt0.S common/bsp.c

CM_ITER ?= 20
CM_SRC  := $(addprefix ../third_party/coremark/,core_list_join.c core_main.c core_matrix.c core_state.c core_util.c) \
           coremark/core_portme.c coremark/ee_printf.c
DHRY_RUNS ?= 2000
# Dhrystone 2.2 as distributed with riscv-tests (copied into sw/dhrystone)
DHRY_SRC := dhrystone/dhrystone.c dhrystone/dhrystone_main.c

TESTS := $(patsubst tests/%.c,$(OUT)/%.elf,$(wildcard tests/*.c))

all: $(OUT)/coremark.elf $(OUT)/dhrystone.elf $(TESTS)
coremark: $(OUT)/coremark.elf
dhrystone: $(OUT)/dhrystone.elf
tests: $(TESTS)

$(OUT)/coremark.elf: $(CM_SRC) $(COMMON) coremark/core_portme.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -O3 -funroll-loops -Icoremark -I../third_party/coremark -DITERATIONS=$(CM_ITER) \
	  -DPERFORMANCE_RUN=1 -DFLAGS_STR='"-O3 -funroll-loops"' $(COMMON) $(CM_SRC) $(LDFLAGS) -o $@

$(OUT)/dhrystone.elf: $(DHRY_SRC) $(COMMON) dhrystone/util.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Idhrystone -DNUMBER_OF_RUNS=$(DHRY_RUNS) -std=gnu89 -fno-inline -Wno-implicit-int -Wno-implicit-function-declaration \
	  $(COMMON) $(DHRY_SRC) $(LDFLAGS) -o $@

$(OUT)/%.elf: tests/%.c $(COMMON)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(COMMON) $< $(LDFLAGS) -o $@

clean:
	rm -rf $(OUT)
