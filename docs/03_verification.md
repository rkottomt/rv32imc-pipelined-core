# 03 — Verification Strategy

> The headline: **every instruction the RTL retires is checked against an
> independent golden model, under randomized bus timing and interrupts, with
> functional coverage proving what was exercised.** Formal proofs (doc 05)
> close the remaining gaps.

## The layers

| Layer | What | Where | Catches |
|---|---|---|---|
| 1. Directed ISA tests | Official `riscv-tests` (113 programs) | `sw/riscv-tests.mk` | Basic per-instruction semantics, CSR/trap behavior |
| 2. ISS co-simulation | Independent Python ISS replays the RTL retirement trace | `verif/iss/` | *Any* architectural divergence, at the exact instruction |
| 3. Constrained-random | Random programs + random bus latency/stalls + random interrupts | `verif/rig/` | Corner cases and interactions nobody thought to write a test for |
| 4. Functional coverage | Bins on instructions, hazards, branches, memory, traps, alignment | `verif/rig/coverage.py` | Shows *what was actually tested* (and drives the generator) |
| 5. Unit tests (cocotb) | Module-level tests: caches, divider, RVC expander | `verif/cocotb/` | Bugs in a block before integration |
| 6. Formal (riscv-formal) | Mathematical proofs over all inputs, bounded depth | `formal/` | Bugs random testing cannot reach |
| 7. Code coverage | Verilator line + toggle coverage over the whole regression | `make code-coverage` | RTL that *no* test executes |
| 8. Directed tests | C / asm tests written to close coverage holes (IRQs, self-modifying code) | `sw/tests/` | Scenarios random generation can't reach |
| 9. Mutation testing | Inject realistic bugs, check the suite catches each | `verif/mutation/` | Weaknesses in the *testbench itself* |

## The retirement trace (RVFI)
- The core implements the **RISC-V Formal Interface**: on every retired instruction, WB reports:
  - PC, the instruction, its trap flag and next PC;
  - source and destination registers and their values;
  - the memory address, read/write byte masks, and data.
- The same port drives both co-simulation and formal verification. One interface, two uses.

## Co-simulation details (`verif/iss/compare.py`)
- **The ISS was written separately from the RTL**, directly from the spec, including its own RVC expander.
  - A shared misunderstanding could still slip through. Formal and the official tests guard against that.
- **Lock-step**: for each RTL retirement record, the ISS executes one instruction and nine fields must match.
- **Non-determinism is synchronized from the DUT**:
  - Cycle counters and MMIO reads take the RTL's value.
  - Interrupts are injected into the ISS at exactly the instruction where the RTL took them. The trace carries the cause.
  - This is how industrial Spike/Imperas co-sim flows work.
- **Failure report**: the last 8 good instructions, then the ISS-vs-RTL fields that differ.

## Constrained-random generator (`verif/rig/rig.py`)
- **Hot register set**: 70% of operands come from 6 registers, so RAW hazards at distance 1–3 happen constantly.
- **Bounded control flow**:
  - forward branches;
  - counted backward loops (reserved counter `x30`);
  - calls to leaf functions (direct and through function pointers);
  - indirect jumps.
  - Programs always terminate.
- **Reserved registers** keep programs well-formed:
  - `x31`, `x9`, `sp`: data base pointers;
  - `x28`/`x29`: trap handler.
- **Exceptions on purpose**: misaligned accesses, illegal encodings, ECALL/EBREAK, illegal CSRs. The trap handler skips the faulting instruction (2 or 4 bytes).
- **Environment randomization** per seed:
  - bus latency 1–4 cycles;
  - 0–49% random back-pressure;
  - random external interrupts (every other seed).

## Coverage closure
The first coverage run hit **75.8%**. The report showed *real blind spots in the generator*:
1. **Load/store addresses always came from the never-written base register.** Address-generation hazards (`addi`→`lw` base, pointer-chasing `lw`→`lw`) were never tested. *Fix*: computed and loaded base pointers.
2. **The assembler silently compressed `jalr`/`ebreak`**, so the 32-bit forms never ran. *Fix*: `.option norvc` regions.
3. **Link values (`jal rd`) were never used as data.** *Fix*: a link-use pattern.
4. **No `c.lw/c.sw/c.lwsp/c.swsp/c.addi4spn/c.addi16sp`.** They need specific base registers. *Fix*: reserved `x9` and `sp` as pointers.
5. **Meaningless bins were removed** (e.g. a DIV result used as a load address) instead of being forced.

Result: **234/234 bins = 100%**.
- Bins: 84 instruction forms, 108 hazard combinations, 12 branch outcomes, 20 access-size/offset combinations, 6 trap types, 4 alignment cases.
- Seeds: 60 passing seeds hit everything. The nightly-style regression runs 500.

## Code coverage → directed tests
- Verilator line+toggle coverage over riscv-tests and 40 random seeds started at **90%**.
- The uncovered lines were informative:
  - **The fetch aligner's stale-prediction repair ("fixup") never ran.** Random programs never rewrite code, so BTB entries never go stale.
    - *Fix*: `sw/tests/bp_fixup.S`, which uses self-modifying code + FENCE.I to make a trained jump overlap a new 32-bit instruction and to orphan a straddling-branch (`xe`) prediction.
    - *Subtlety*: the first version trained *conditional* branches. Those are only predicted taken when the gshare counter agrees, and the global history after the code rewrite was different, so no stale prediction was made and the path still wasn't hit. Switching to unconditional jumps made the test deterministic.
  - **Timer and software interrupts, and vectored `mtvec`, were never exercised.** Random tests only pulse the external interrupt line.
    - *Fix*: `sw/tests/irq_test.c` covers CLINT timer/software IRQs, masking by `mie`/`mstatus.MIE`, vectored dispatch, and `mcycle` writes.
- After: **92%**, the CSR file and front end at 100% of lines. The remainder is constant outputs (e.g. `rvfi_halt`) and unreachable toggles.

## Mutation testing: who verifies the verifier?
- `verif/mutation/mutate.py` injects 16 realistic bugs, one at a time. They include:
  - removed forwarding paths, a missing hazard check, a missing write-through;
  - signed/unsigned compare mix-ups, wrong RVC expansion;
  - MRET behavior;
  - stale fetch responses not dropped;
  - cache bypass and write-back removal, FENCE.I coherence;
  - and the two real bugs found earlier.
- Each mutant is rebuilt and run through a quick suite. Results: `docs/mutation_results.md`.
- **Round 1: 15/16.**
  - The survivor: *the D-cache drops dirty lines on eviction*.
  - The quick suite's SoC tests all fit in the 4 KiB cache (no evictions), and random co-sim ran only on the cacheless core.
  - *Fix*: add random co-sim on a tiny-cache SoC to the quick suite.
- **Round 2: 16/16.**
- *Lesson*: a passing regression proves nothing about bugs it cannot observe. Mutation testing measures the regression's ability to *detect*, not just to *pass*.

## Bugs found by verification

| # | Found by | Bug | Fix |
|---|---|---|---|
| 1 | riscv-tests `instret_overflow` | `minstret` counted at WB, so a CSR read in MEM missed the instruction just ahead of it | Count retirement at the MEM commit point; CSR writes to the counter suppress that cycle's increment |
| 2 | Random co-sim (12/20 seeds failed) | **Divider latched a stale operand.** DIV directly after a load, with memory latency > 1: the divider captured operands on its first EX cycle while the load was still waiting in WB, so the bypass returned the old register value. | The divider only starts when there is no MEM/WB stall (`hold` input), i.e. when the bypass network is valid |
| 3 | Random (timeouts) | *Testbench bug, not RTL*: generator emitted `auipc+jalr +12`, which lands mid-instruction when the next `nop` gets compressed | Use `%pcrel_hi/%pcrel_lo` relocations. Co-sim showed RTL == ISS, which pointed straight at the program |
| 4 | riscv-formal `pc_fwd` | `rvfi_intr` not set when the first instruction of a trap handler itself traps (interrupt → handler → illegal instruction) | Flag the first record after *any* trap event. This also fixed the co-sim IRQ flag for that case |
| 5 | Yosys (synthesis lint) | Latch inferred for a `for`-loop variable in the CSR read mux (only assigned on some paths) | Direct indexing instead of a loop |
| 6 | Performance profiling | Branch predictor never predicted 32-bit branches straddling two fetch words, so ~half the branches in compressed code were unpredictable (28% mispredict) | Key them by their *end* word (`xe` flag): 10% mispredict, +11% IPC |
| 7 | Directed test (*test* bug) | Vector table written with `j`, which the assembler compressed to 2 bytes, breaking 4-byte slot spacing | `.option norvc` in the table. ISS == RTL pointed at the test |
| 8 | Random co-sim (*test* bug) | Exit sequence used a register the trap handler clobbers; an interrupt between two instructions changed the exit code | Use a handler-safe register |

Bug #2 is the classic class of pipeline bug: **a multi-cycle unit sampling bypassed operands at the wrong time.**
- The directed tests could not hit it, because riscv-tests run with 1-cycle memory.
- Randomized latency plus co-sim found it in seconds.

## How to run
```
source env.sh
make run-tests                                        # 113 riscv-tests
make run-tests SIMARGS="+stall=40 +ilat=3 +dlat=4"    # ... under bus stress
verif/rig/run_random.sh 1 100                         # 100 random seeds, co-simulated
KEEP_TRACES=1 verif/rig/run_random.sh 1 60 && python3 verif/rig/coverage.py build/random/*.trace
make directed                                         # directed tests, co-simulated
make code-coverage                                    # Verilator line/toggle coverage
python3 verif/mutation/mutate.py                      # mutation testing
make regress                                          # everything except formal
```

## Design Q&A
- **Why is a golden-model comparison better than self-checking tests?** A self-checking test only checks what its author thought to check. Co-sim checks *every* architectural effect of *every* instruction, so random programs need no expected values.
- **How do you handle interrupts in co-sim, since they're timing-dependent?** The DUT decides when and the model follows: the RTL trace marks where an interrupt was taken, and the ISS takes it at the same instruction boundary. What we verify is that the RTL takes it *precisely* (correct `mepc`/`mcause`, nothing lost or duplicated).
- **What does 100% functional coverage *not* tell you?** That the checker is right, or that untracked scenarios work. Hence code coverage, formal proofs and mutation testing as complements.
