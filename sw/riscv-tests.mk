# Build and run the official riscv-tests (p environment) against the core.
# Each test is built twice: once as plain RV32I/M code and once with the
# assembler allowed to emit compressed instructions (-march=..c), which
# exercises the RVC expander and the fetch aligner on real code.
RT       := $(ROOT)/third_party/riscv-tests
RT_OUT   := $(BUILD)/riscv-tests
CC       := riscv-none-elf-gcc
RT_CFLAGS := -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
             -I$(RT)/env/p -I$(RT)/isa/macros/scalar -T$(RT)/env/p/link.ld

RV32UI := simple add addi and andi auipc beq bge bgeu blt bltu bne fence_i jal jalr lb lbu lh lhu lui \
          lw or ori sb sh sll slli slt slti sltiu sltu sra srai srl srli sub sw xor xori ld_st st_ld
# ma_data is omitted: it requires hardware misaligned access support; this
# core traps instead (allowed by the spec, checked by rv32mi-*-misaligned).
RV32UM := mul mulh mulhsu mulhu div divu rem remu
RV32UC := rvc
RV32MI := csr mcsr illegal ma_addr ma_fetch scall sbreak shamt zicntr instret_overflow \
          lh-misaligned lw-misaligned sh-misaligned sw-misaligned

RT_ELFS := $(foreach t,$(RV32UI),$(RT_OUT)/rv32ui-p-$(t) $(RT_OUT)/rv32ui-pc-$(t)) \
           $(foreach t,$(RV32UM),$(RT_OUT)/rv32um-p-$(t) $(RT_OUT)/rv32um-pc-$(t)) \
           $(foreach t,$(RV32UC),$(RT_OUT)/rv32uc-p-$(t)) \
           $(foreach t,$(RV32MI),$(RT_OUT)/rv32mi-p-$(t))

$(RT_OUT)/rv32ui-p-%: $(RT)/isa/rv32ui/%.S
	@mkdir -p $(@D); $(CC) -march=rv32i_zicsr_zifencei $(RT_CFLAGS) -I$(RT)/isa/rv64ui $< -o $@
$(RT_OUT)/rv32ui-pc-%: $(RT)/isa/rv32ui/%.S
	@mkdir -p $(@D); $(CC) -march=rv32ic_zicsr_zifencei $(RT_CFLAGS) -I$(RT)/isa/rv64ui $< -o $@
$(RT_OUT)/rv32um-p-%: $(RT)/isa/rv32um/%.S
	@mkdir -p $(@D); $(CC) -march=rv32im_zicsr_zifencei $(RT_CFLAGS) -I$(RT)/isa/rv64um $< -o $@
$(RT_OUT)/rv32um-pc-%: $(RT)/isa/rv32um/%.S
	@mkdir -p $(@D); $(CC) -march=rv32imc_zicsr_zifencei $(RT_CFLAGS) -I$(RT)/isa/rv64um $< -o $@
$(RT_OUT)/rv32uc-p-%: $(RT)/isa/rv32uc/%.S
	@mkdir -p $(@D); $(CC) -march=rv32imc_zicsr_zifencei $(RT_CFLAGS) -I$(RT)/isa/rv64uc $< -o $@
$(RT_OUT)/rv32mi-p-%: $(RT)/isa/rv32mi/%.S
	@mkdir -p $(@D); $(CC) -march=rv32imc_zicsr_zifencei $(RT_CFLAGS) -I$(RT)/isa/rv64si -I$(RT)/isa/rv64mi $< -o $@

tests: $(RT_ELFS)

# SIMARGS lets you add e.g. "+stall=30 +dlat=3" to stress the bus handshakes.
SIMARGS ?=
run-tests: $(SIM_CORE) tests
	@pass=0; fail=0; failed=""; \
	for t in $(RT_ELFS); do \
	  if $(SIM_CORE) +elf=$$t $(SIMARGS) > $$t.log 2>&1; then pass=$$((pass+1)); \
	  else fail=$$((fail+1)); failed="$$failed $$(basename $$t)"; fi; \
	done; \
	echo "riscv-tests: $$pass passed, $$fail failed"; \
	[ -z "$$failed" ] || { echo "FAILED:$$failed"; exit 1; }
