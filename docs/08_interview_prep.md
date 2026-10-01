# 08 — Interview Prep: How to Talk About This Project

## The 30-second pitch
> "I designed a 5-stage pipelined RISC-V CPU, RV32IMC with machine-mode traps
> and interrupts, plus caches and a small SoC, and verified it the way an
> industry DV team would:
> - lock-step co-simulation against a golden-model ISS I wrote;
> - a constrained-random instruction generator with functional coverage
>   closure to 100%;
> - riscv-formal proofs;
> - mutation testing to prove the testbench catches bugs.
>
> Verification found real bugs: a divider operand race, a formal-only trap
> corner case, and a branch-predictor flaw I found through performance
> profiling that cost 11% IPC. It runs CoreMark at 2.9 CoreMark/MHz and
> closes timing at 31 MHz on a Lattice ECP5."

## The 2-minute walkthrough (draw this)
```
 IF ──► [fetch queue] ──► ID ──► EX ──► MEM ──► WB
 BTB/gshare/RAS      align+RVC  ALU    D$/CSR   load align
 predict next PC     decode     MUL    TRAPS    regfile write
                     regfile    DIV    commit   RVFI trace
                     hazard     branch
                                resolve
```
Hit these points in order:
1. Hazards: forwarding, load-use stall, mispredict redirect.
2. Precise traps at the MEM commit point.
3. Compressed instructions and the aligner.
4. Caches and FENCE.I coherence.
5. The verification stack.
6. The numbers.

## Five stories to have ready (STAR format)
1. **Divider operand bug** (`03_verification.md`):
   - *Situation*: all 113 riscv-tests passed.
   - *Task*: stress the pipeline harder.
   - *Action*: constrained-random tests with random memory latency plus co-sim. 12 of 20 seeds failed on a DIV right after a load, because the divider latched operands while the load was still waiting in WB.
   - *Result*: a `hold` input. Also became mutation M06, which the suite now kills.
2. **Coverage closure 75.8% → 100%**: the report revealed blind spots in the *generator* (base registers never written, the assembler auto-compressing instructions). It's about measuring what you tested, not only how many tests passed.
3. **Formal-only bug**: an interrupt whose handler's first instruction traps. Simulation never produced it; riscv-formal's `pc_fwd` check did. It also exposed a latent co-sim desynchronization.
4. **Branch predictor flaw found by profiling**:
   - *Situation*: 28% mispredict rate.
   - *Action*: a size sweep ruled out capacity, a debug build showed all offenders were straddling 32-bit branches, and I redesigned BTB keying.
   - *Result*: +11% IPC.
5. **Timing closure 24.7 → 31.1 MHz**: read the nextpnr critical path, broke combinational paths across stages (registered redirect, IRQs, predictor training, pipelined MUL). Each change was re-verified, and the next step is quantified (6th stage, ~+25% net).

## Likely questions and crisp answers

**Pipeline / micro-architecture**
- *What's the mispredict penalty?* 4 cycles: EX resolves, then the registered redirect, refetch, and the queue refill. A correctly predicted taken branch costs 0 bubbles, because the BTB is looked up at fetch.
- *Why does the core take exceptions in MEM?* It's the last stage before architectural state changes, so it's the single commit point. Everything older is in WB and completes; everything younger is flushed.
- *How are interrupts made precise?* An interrupt is "taken" on the instruction in MEM. That instruction doesn't execute, `mepc` points at it, and MRET re-executes it.
- *How does forwarding work with a stalled EX?* EX re-captures its forwarded operands every stalled cycle, because a producer can leave the bypass network while EX waits.
- *How do compressed instructions work?* The fetch queue holds 32-bit words. The aligner consumes 16-bit parcels and builds 32-bit instructions that straddle words. The RVC expander maps every 16-bit encoding to its 32-bit equivalent, so the decoder only knows 32-bit instructions.
- *gshare?* 2-bit counters indexed by PC XOR global history. It captures correlation between branches.
- *RAS?* A 4-entry return-address stack. Calls push and returns pop. It's speculative and not repaired after a mispredict, which is safe because EX verifies every prediction.

**Memory system**
- *Write-back vs write-through?* Write-back for bandwidth. It needs dirty bits, eviction write-back, and a flush for FENCE.I.
- *Self-modifying code?* FENCE.I goes to the D-cache as a flush request. It's accepted only after all dirty lines are written back; then the I-cache is invalidated and fetch restarts.
- *BRAM read-during-write?* It returns old data, so the D-cache bypasses the last store into the next lookup.

**Verification**
- *Why a golden model?* A self-checking test only checks what its author imagined. Co-sim checks every architectural effect of every instruction.
- *How do you handle non-determinism (interrupts, timers)?* The DUT decides. The trace records where an interrupt was taken and the ISS takes it there. Counter and MMIO reads take the DUT's value.
- *What's the difference between functional and code coverage?* Code coverage: which RTL lines and toggles were exercised. Functional coverage: which *scenarios* from the verification plan happened. They found different holes here:
  - functional coverage exposed generator blind spots;
  - code coverage exposed the never-run predictor repair logic and timer interrupts.
- *How do you know your testbench is good?* Mutation testing: inject realistic bugs and check every one is caught (`verif/mutation/`).
- *Formal vs simulation?* Formal is exhaustive within a bound and great for control logic and protocol properties. Simulation scales to full programs and arithmetic. Use both.
- *UVM?* This project uses a Python (cocotb) and C++ testbench. The concepts map directly:
  - generator ≈ sequence/sequencer;
  - bus models ≈ drivers/responders;
  - RVFI trace ≈ monitor;
  - ISS compare ≈ scoreboard with a reference model;
  - `coverage.py` ≈ covergroups.

**FPGA**
- *What limits Fmax?* Load data → bypass → ALU. The next fix is an extra stage with a 2-cycle load-use penalty, net ~+25%.
- *Why ECP5?* It has a fully open-source flow (Yosys + nextpnr), so the project is reproducible without vendor licenses. The RTL is vendor-neutral.

## Things to be honest about (interviewers respect this)
- **Single-issue, in-order, machine mode only.** No MMU, no U/S modes.
- **Formal proofs are bounded** (BMC) and use ALTOPS for mul/div.
- **CoreMark** is run in simulation with 20 iterations. The official 10-second rule needs hardware; per-MHz numbers from cycle counts are standard for comparison.
- **The bus is a simple valid/ready protocol**, not AXI. An AXI4 bridge is straightforward future work.
