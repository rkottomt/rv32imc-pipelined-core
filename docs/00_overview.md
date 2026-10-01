# 00 — Project Overview and Study Guide

Read the docs in order. Each one ends with interview Q&A.

| Doc | Topic |
|---|---|
| 00_overview.md | This file: goals, tools, repo map, progress log |
| 01_microarchitecture.md | 5-stage pipeline, hazards, forwarding, traps |
| 02_frontend.md | Fetch queue, RVC aligner, BTB/gshare/RAS |
| 03_verification.md | Verification strategy: riscv-tests, ISS co-sim, random tests, coverage |
| (more added as the project grows) | |

## Toolchain (all open source, no hardware needed)

| Tool | Role |
|---|---|
| Verilator | Cycle-accurate simulator (compiles Verilog to C++). Fast enough to run CoreMark. |
| Icarus Verilog | Second simulator (event-driven), used by cocotb unit tests |
| cocotb | Python testbenches for unit-level verification |
| Yosys | Synthesis |
| nextpnr-ecp5 | Place and route for a Lattice ECP5 FPGA; gives real timing (Fmax) |
| SymbiYosys + SMT solvers | Formal verification (riscv-formal) |
| riscv-none-elf-gcc | Compiles tests and benchmarks |

Setup: `scripts/fetch_third_party.sh`, then install the OSS CAD Suite and xPack RISC-V GCC into `tools/`, then `source env.sh`.

## Repo map
```
rtl/core/     the CPU (rv_core.v is the top)
rtl/cache/    I-cache and D-cache
rtl/soc/      SoC top: interconnect, RAM, UART, timer, GPIO
sim/          Verilator C++ testbenches
sw/           test programs, benchmarks, linker scripts
verif/        Python ISS (golden model), random instruction generator, cocotb tests
formal/       riscv-formal configuration and proofs
synth/        Yosys / nextpnr scripts and reports
docs/         you are here
```

## Progress log
- **M1: Toolchain.** OSS CAD Suite + xPack GCC + cocotb installed locally.
- **M2: Core RTL.** All 113 applicable riscv-tests pass (rv32ui/um/uc/mi, each user test built both with and without compressed instructions). They also pass with 40% random bus stalls and 3–4 cycle memory latency.
  - Bug found: `minstret` was counted at WB instead of the MEM commit point (caught by `rv32mi-instret_overflow`).
