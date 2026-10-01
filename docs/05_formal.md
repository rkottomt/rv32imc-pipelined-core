# 05 — Formal Verification (riscv-formal)

## What formal verification adds
- Simulation checks the inputs you happen to try.
- Formal verification uses a solver to *prove* a property holds for **every possible input sequence** up to a depth (bounded model checking, BMC). If it doesn't hold, the tool hands back a concrete counterexample waveform.

## riscv-formal
**riscv-formal** (YosysHQ) is the standard formal framework for RISC-V cores.
- The core exposes the **RVFI** retirement interface, the same one co-simulation uses.
- riscv-formal ships a formal spec of every instruction and checks each retirement against it.

### Setup
- `formal/checks.cfg`: which checks to run and how deep.
- `formal/wrapper.sv`: connects the core to "any value" environment models. The bus models only obey the protocol (in-order responses, never more responses than requests). Data, latency, ready signals and interrupt lines are completely unconstrained.
- `formal/run.sh`: generates the SymbiYosys jobs and runs them in parallel.
- Mul/div use `RISCV_FORMAL_ALTOPS`: the M unit is swapped for cheap stand-in functions defined by riscv-formal, because SMT solvers handle 32-bit multiplication very badly.
  - This checks how M-instructions *flow through the pipeline*: decode, forwarding, write-back.
  - The arithmetic itself is covered by simulation: 6,600 cocotb vectors plus co-sim.
- The predictor tables are shrunk (4-entry BTB/BHT) to cut solver time. Prediction can't affect correctness anyway; that's the point of the design.

## Checks (77 jobs)

| Check | Proves |
|---|---|
| `insn_*` (70) | Every RV32IMC instruction: operands read, result written, next PC, memory address/masks/data all match the ISA spec, regardless of what happened before |
| `reg` | Register values read by an instruction equal the last value written to that register (no forwarding/hazard bugs) |
| `pc_fwd` / `pc_bwd` | Each instruction's PC equals the previous one's next-PC (no lost or duplicated instructions, correct branch redirects) |
| `unique` | Retirement order numbers are never reused |
| `causal` | A register is never read before the instruction that writes it has retired (causality) |
| `ill` | Illegal encodings trap |
| `cover` | Sanity: the environment can actually retire instructions (proofs are not vacuous) |

## Results (final RTL)

| Group | Result |
|---|---|
| 70 instruction checks (`insn_*`, all of RV32IMC) | **70/70 PASS** |
| `pc_bwd`, `unique`, `causal`, `ill`, `cover` | **PASS** |
| `reg`, `pc_fwd` | **PASS** at depth 12. At depth 16 they did not finish within a 2-hour budget, with no failure found |

Total: **77/77 checks pass, zero failures.**
- Depth 12 is enough to cover a full trip through the pipeline: instructions retire about 7 cycles after reset.
- `pc_fwd` is the check that caught the `rvfi_intr` bug on the earlier RTL.

## Solver engineering (interview story)
- **Bitwuzla**, the default here, did not finish `insn_add` in more than 10 minutes at depth 24. Depth 12 is enough for this pipeline, since an instruction retires about 7 cycles after reset.
- Benchmarked three engines on the same check:

| Engine | `insn_add` (depth 12) |
|---|---|
| smtbmc bitwuzla | > 10 min (stopped) |
| smtbmc bitwuzla + `memory_map` | > 10 min (stopped) |
| **smtbmc yices** | **74 s** |

  Yices is now the configured solver.

## Bug found by formal
**`rvfi_intr` on a trapping handler entry.**
- The counterexample, found on the old RTL:
  1. An interrupt is taken.
  2. The *first instruction of the handler* is itself illegal and traps.
- RVFI requires that record to carry `rvfi_intr=1` (first instruction of a trap handler). My logic suppressed `intr` on trapping records, so the PC-continuity check (`pc_fwd`) saw an unexplained PC jump.
- Simulation never hit it: random programs install a valid handler, so the handler's first instruction never traps.
- The fix also corrected the co-simulation flag (`dbg_irq`), which would otherwise have desynchronized the ISS in exactly that scenario.

## How to run
```
source env.sh
formal/run.sh                      # all checks
formal/run.sh 'insn_c_.*|pc_fwd'   # a subset (regex)
JOBS=8 formal/run.sh               # parallelism
```
Results go to `third_party/riscv-formal/cores/rvcore/checks/<check>/status`. Counterexamples are in `.../engine_0/trace.vcd`; open them in GTKWave.

## Interview Q&A
- **BMC vs full proof?** BMC proves "no bug within N cycles of reset". For a pipeline that drains in ~7 cycles, and with *any* program state reachable in that window, this is very strong for per-instruction properties. Unbounded proofs need k-induction plus invariants. Future work.
- **Why ALTOPS?** The point is to verify the pipeline's control. Proving the multiplier is a separate, much harder (equivalence-checking) problem. Simulation with a large corner-case vector set covers it.
- **Why constrain the environment at all?** To match real hardware. An unconstrained bus that sends responses nobody asked for would produce false failures. Under-constraining hides nothing. Over-constraining can hide bugs, so the wrapper only encodes the protocol rules.
