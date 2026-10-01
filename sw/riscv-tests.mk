# Build and run the official riscv-tests (p environment).
#
# Each user-level test is built twice: once as plain RV32I/M code ("-p-") and
# once with the assembler allowed to emit compressed instructions ("-pc-"),
# which exercises the RVC expander and the fetch aligner on real code.
# Every test is linked twice as well:
#   build/riscv-tests/      at 0x8000_0000, for the core-level testbench
#   build/riscv-tests-soc/  at 0x0000_0000, for the full SoC (tohost -> SIMCTRL)
RT        := $(ROOT)/third_party/riscv-tests
RT_OUT    := $(BUILD)/riscv-tests
RT_SOC_OUT:= $(BUILD)/riscv-tests-soc
RT_CC     := riscv-none-elf-gcc
RT_CFLAGS := -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
             -Wl,--no-warn-rwx-segments -I$(RT)/env/p -I$(RT)/isa/macros/scalar

RV32UI := simple add addi and andi auipc beq bge bgeu blt bltu bne fence_i jal jalr lb lbu lh lhu lui \
          lw or ori sb sh sll slli slt slti sltiu sltu sra srai srl srli sub sw xor xori ld_st st_ld
# ma_data is omitted: it requires hardware misaligned access support; this
# core traps instead (allowed by the spec, checked by rv32mi-*-misaligned).
RV32UM := mul mulh mulhsu mulhu div divu rem remu
RV32UC := rvc
RV32MI := csr mcsr illegal ma_addr ma_fetch scall sbreak shamt zicntr instret_overflow \
          lh-misaligned lw-misaligned sh-misaligned sw-misaligned

# $(1)=test name  $(2)=source  $(3)=march  $(4)=extra include dir
define RT_TEST
$(RT_OUT)/$(1): $(2)
	@mkdir -p $$(@D); $(RT_CC) -march=$(3) $(RT_CFLAGS) -I$(4) -T$(RT)/env/p/link.ld $$< -o $$@
$(RT_SOC_OUT)/$(1): $(2) $(ROOT)/sw/soc.ld
	@mkdir -p $$(@D); $(RT_CC) -march=$(3) $(RT_CFLAGS) -I$(4) -T$(ROOT)/sw/soc.ld $$< -o $$@
RT_NAMES += $(1)
endef

$(foreach t,$(RV32UI),$(eval $(call RT_TEST,rv32ui-p-$(t),$(RT)/isa/rv32ui/$(t).S,rv32i_zicsr_zifencei,$(RT)/isa/rv64ui)))
$(foreach t,$(RV32UI),$(eval $(call RT_TEST,rv32ui-pc-$(t),$(RT)/isa/rv32ui/$(t).S,rv32ic_zicsr_zifencei,$(RT)/isa/rv64ui)))
$(foreach t,$(RV32UM),$(eval $(call RT_TEST,rv32um-p-$(t),$(RT)/isa/rv32um/$(t).S,rv32im_zicsr_zifencei,$(RT)/isa/rv64um)))
$(foreach t,$(RV32UM),$(eval $(call RT_TEST,rv32um-pc-$(t),$(RT)/isa/rv32um/$(t).S,rv32imc_zicsr_zifencei,$(RT)/isa/rv64um)))
$(foreach t,$(RV32UC),$(eval $(call RT_TEST,rv32uc-p-$(t),$(RT)/isa/rv32uc/$(t).S,rv32imc_zicsr_zifencei,$(RT)/isa/rv64uc)))
$(foreach t,$(RV32MI),$(eval $(call RT_TEST,rv32mi-p-$(t),$(RT)/isa/rv32mi/$(t).S,rv32imc_zicsr_zifencei,$(RT)/isa/rv64mi -I$(RT)/isa/rv64si)))

RT_ELFS     := $(addprefix $(RT_OUT)/,$(RT_NAMES))
RT_SOC_ELFS := $(addprefix $(RT_SOC_OUT)/,$(RT_NAMES))

tests: $(RT_ELFS)
tests-soc: $(RT_SOC_ELFS)

# SIMARGS lets you add e.g. "+stall=30 +dlat=3" to stress the bus handshakes.
SIMARGS ?=
run-tests: $(SIM_CORE) tests
	@pass=0; fail=0; failed=""; \
	for t in $(RT_ELFS); do \
	  if $(SIM_CORE) +elf=$$t $(SIMARGS) > $$t.log 2>&1; then pass=$$((pass+1)); \
	  else fail=$$((fail+1)); failed="$$failed $$(basename $$t)"; fi; \
	done; \
	echo "riscv-tests (core): $$pass passed, $$fail failed"; \
	[ -z "$$failed" ] || { echo "FAILED:$$failed"; exit 1; }

run-tests-soc: $(SIM_SOC) tests-soc
	@pass=0; fail=0; failed=""; \
	for t in $(RT_SOC_ELFS); do \
	  if $(SIM_SOC) +elf=$$t $(SIMARGS) > $$t.log 2>&1; then pass=$$((pass+1)); \
	  else fail=$$((fail+1)); failed="$$failed $$(basename $$t)"; fi; \
	done; \
	echo "riscv-tests (SoC): $$pass passed, $$fail failed"; \
	[ -z "$$failed" ] || { echo "FAILED:$$failed"; exit 1; }
