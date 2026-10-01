# Resume Material

## Project title line
**RV32IMC Pipelined RISC-V CPU & SoC — Design and Verification** | Verilog, SystemVerilog Assertions, Python (cocotb), C++, Verilator, SymbiYosys, Yosys/nextpnr

## Bullet options (pick 3–5; numbers are from this repo)

**Design**
- Designed a 5-stage in-order RV32IMC RISC-V CPU in Verilog:
  - full forwarding, load-use hazard detection and precise machine-mode traps and interrupts;
  - a decoupled fetch unit with a compressed-instruction aligner;
  - BTB + gshare + return-address-stack branch prediction.
- Built an SoC around the core:
  - 2-way set-associative I-cache and write-back D-cache with FENCE.I coherence;
  - a bus arbiter, CLINT timer, UART and GPIO;
  - runs CoreMark at **2.9 CoreMark/MHz** and Dhrystone at **1.03 DMIPS/MHz**.

**Verification**
- Built a verification environment:
  - a golden-model ISS (Python) in lock-step co-simulation with the RTL via the RISC-V Formal Interface;
  - a constrained-random instruction generator with randomized bus latency and back-pressure and random interrupts;
  - result: **100% functional coverage** (234 bins) and 92% line/toggle code coverage.
- Passed all 113 applicable official riscv-tests. Proved the core against the ISA spec with **riscv-formal** (77 SymbiYosys BMC checks). Cut proof time >8× through solver benchmarking.
- Validated testbench quality with **mutation testing**: 16 injected realistic pipeline and cache bugs, all detected.
- Found and fixed 6+ RTL bugs, among them:
  - a divider operand race under memory latency (random co-sim);
  - a trap/interrupt corner case visible only to formal;
  - a branch-predictor design flaw found through profiling (**+11% IPC**).

**Implementation / performance**
- Closed timing on a Lattice ECP5 FPGA: improved Fmax **24.7 → 34.7 MHz (+40%)** by analyzing critical paths and re-pipelining (redirect, interrupt, predictor-training, performance-counter and multiplier paths). Quantified the IPC/frequency trade-offs.
- Ran a micro-architectural design-space study:
  - caches give >10× speedup with DRAM-like latency;
  - branch prediction gives +30%;
  - cache-size and predictor-size sensitivity.

## One-liner for LinkedIn / headline
Designed and formally verified a pipelined RV32IMC RISC-V CPU and SoC: co-simulation, constrained-random, 100% functional coverage, riscv-formal, ECP5 timing closure.
