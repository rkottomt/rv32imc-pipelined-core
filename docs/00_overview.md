# 00 — Project Overview and Study Guide

Read the docs in order. Each one ends with interview Q&A.

| Doc | Topic |
|---|---|
| 00_overview.md | This file: tools, repo map, progress log |
| 01_microarchitecture.md | 5-stage pipeline, hazards, forwarding, precise traps |
| 02_frontend.md | Fetch queue, RVC aligner, BTB/gshare/RAS |
| 03_verification.md | riscv-tests, ISS co-sim, constrained-random, coverage, mutation testing, bug list |
| 04_caches_soc.md | I/D caches, FENCE.I coherence, SoC bus and peripherals |
| 05_formal.md | riscv-formal setup, checks, solver engineering, formal-found bug |
| 06_fpga_timing.md | ECP5 flow, utilization, timing-closure log |
| 07_performance.md | CoreMark/Dhrystone, design-space study, predictor bug found by profiling |
| 08_interview_prep.md | Pitch, stories, likely questions |
| RESUME.md | Resume bullets |

**Suggested study plan:**
1. Read 01 and 02 with `rtl/core/rv_core.v` and `rtl/core/rv_frontend.v` open.
2. Run one riscv-test with a waveform: `make sim TRACE=1`, then `build/sim_core/Vrv_core +elf=build/riscv-tests/rv32ui-p-add +fst=add.fst`, then open it in GTKWave.
3. Read 03, then run `verif/rig/run_random.sh 1 5` and look at a generated `.S` file.
4. Read 04–07.
5. Rehearse 08 out loud.

## Toolchain (all open source, no hardware needed)

| Tool | Role |
|---|---|
| Verilator | Cycle-accurate simulator (Verilog → C++). Fast enough to run CoreMark |
| Icarus Verilog + cocotb | Python unit-level testbenches |
| Yosys + nextpnr-ecp5 | Synthesis and place-and-route for the Lattice ECP5; real timing numbers |
| SymbiYosys + Yices | Formal verification (riscv-formal) |
| riscv-none-elf-gcc (xPack) | Compiles tests and benchmarks |

**Setup**
1. Download the OSS CAD Suite release into `tools/oss-cad-suite`.
2. Download the xPack RISC-V GCC into `tools/`.
3. Create a venv: `python3 -m venv .venv && .venv/bin/pip install cocotb pytest`.
4. Run `scripts/fetch_third_party.sh`, then `source env.sh`.

## Progress log
- **M1 Toolchain.** OSS CAD Suite, xPack GCC, cocotb.
- **M2 Core RTL.** 5-stage RV32IMC pipeline. 113/113 riscv-tests pass.
  - Bug: `minstret` counted at the wrong stage.
- **M3 Verification.**
  - Python ISS and lock-step co-sim.
  - Constrained-random generator: functional coverage 75.8% → 100% via coverage-driven fixes.
  - Bug: divider operand race (found by random co-sim with memory latency).
- **M4 Caches + SoC.**
  - I$, write-back D$ with flush, arbiter, RAM, CLINT/UART/GPIO.
  - SoC passes all riscv-tests.
  - Tiny-cache/slow-RAM stress co-sim.
  - cocotb unit tests (exhaustive RVC, M-unit, D-cache scoreboard).
- **M5 Formal.**
  - riscv-formal integration; solver benchmarking (Yices 74 s vs Bitwuzla >10 min).
  - Bug: `rvfi_intr` when the handler's first instruction traps.
- **M6 Software.** C runtime, CoreMark and Dhrystone ports, directed tests (timer/software IRQs, vectored `mtvec`, self-modifying code).
- **M7 FPGA.**
  - ECP5 synthesis/PnR; timing closure 24.7 → 31.1 MHz.
  - Lint finding: inferred latch in the CSR read mux.
- **M8 Performance.**
  - Design-space study.
  - Bug found by profiling: straddling branches were never predicted. Fix: +11% IPC.
- **M9 Coverage and mutation.** Verilator code coverage (holes closed with directed tests), mutation testing, CI, docs.
