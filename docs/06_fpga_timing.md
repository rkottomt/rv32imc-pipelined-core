# 06 — FPGA Implementation and Timing Closure

**Target:** Lattice ECP5 LFE5U-85F (Radiona ULX3S board).
**Flow:** Yosys `synth_ecp5 -abc9`, then nextpnr-ecp5 (timing-driven placement and routing), then `ecppack` produces a bitstream.

```
make -C synth FREQ=60      # synthesize + place & route, report Fmax
make -C synth area         # per-module utilization
make -C synth bitstream    # .bit file for the board
```

## Resource use (full SoC, 64 KiB RAM)

| Resource | Used | Of 85F | Notes |
|---|---|---|---|
| LUT4 (logic) | ~13k | 15% | |
| Flip-flops | ~3.7k | 4% | |
| DP16KD block RAM | 54 | 25% | 32 = 64 KiB RAM, 12 = I$ data, 8 = D$ data, 2 = BHT |
| MULT18X18D DSP | 4 | 2% | 33×33 multiplier |

Per-module (from `synth/area_report.txt`):
- **front end**: ~2.9k LUT. BTB/BHT, fetch queue, aligner.
- **CSR file**: ~2.7k LUT. Six 64-bit performance counters plus the read mux. The obvious next area optimization: 32-bit or fewer counters.
- **ALU**: ~0.8k LUT.
- **RVC expander**: ~250 LUT.
- **register file**: 32 DPR16X4 LUT-RAM cells.

## Timing closure log (a strong interview story)
Fmax measured with nextpnr targeting 60 MHz. The constraint file originally pinned 25 MHz, and nextpnr stops optimizing once a target is met, so it had to be removed to see the true Fmax.

| Step | Change | Fmax | Cost |
|---|---|---|---|
| 0 | Baseline | 24.7 MHz | – |
| 1 | Register interrupt lines (CLINT compare, ext IRQ). Branch mispredict redirect applied one cycle after EX, from a register; the wrong-path instruction in EX is killed | 30.9 MHz | +1 cycle per mispredict (IRQ latency +1 is invisible) |
| 2 | 2-cycle multiplier (operands registered before the DSP). D-cache tag compare moved one cycle earlier (computed when the RAM read is issued) | 30.9 MHz | +1 cycle per MUL |
| 3 | Branch-predictor training registered (BTB/BHT write ports no longer driven by EX compare logic) | **31.1 MHz** | none (training one cycle later) |

### How each critical path was found
- The `Critical path report` in `build/synth/pnr.log` was mapped back to RTL net names.
- **Path 0**:
  `mtime` 64-bit compare → `irq_pending` → MEM trap decision → data-bus request valid → cache handshake → stall → forwarding → EX branch compare → `ex_redirect` → fetch queue pointers.
  One combinational path spanning four stages and two modules.
- **Path 1**: D-cache data → load align → forwarding → DSP multiplier → EX/MEM.
- **Path 2**: D-cache data → load align → forwarding → branch resolve → BTB write enable.
- **Path 3 (current)**: D-cache BRAM output → way mux → load align/sign-extend → forwarding mux → divider operand negate / ALU adder → EX register.
  - 14 ns logic + 18 ns routing.
  - This is the textbook "load data into the bypass network" path.

### Next step (not done, documented trade-off)
- Register load data in a 6th stage (MEM2) so the bypass network never sees raw BRAM output.
- **Expected**: roughly 40–45 MHz.
- **Cost**: load-use penalty 1 → 2 cycles. On CoreMark (~20% loads, ~35% of them used immediately) that is roughly −6% IPC for about +35% frequency: **a net ~+25% performance**.
- This is the classic frequency-vs-IPC trade-off. Every commercial core makes it.

### Every timing change is re-verified
After each step: riscv-tests on the core and SoC, the random co-sim regression (100 seeds core + 30 seeds tiny-cache SoC), cocotb unit tests and CoreMark. Timing changes are exactly where pipeline bugs come from, e.g. stale operands after adding a stage.

## Interview Q&A
- **Why is routing 56% of the critical path?** FPGA routing goes through programmable switches. Long paths that cross many modules are spread across the die. Pipelining shortens paths *and* lets the placer cluster logic.
- **Why register the mispredict instead of making the comparison faster?** The comparison sits at the end of the longest datapath (forward → add → compare). Registering it removes the downstream fetch logic from that path entirely, for a 1-cycle penalty on about 10% of branches.
- **How do you know the critical path isn't a false path?** Here everything is single-clock and functional. Multi-clock designs need CDC constraints or false-path declarations.
