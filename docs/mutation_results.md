# Mutation Testing Results (verif/mutation/mutate.py)

Each mutant is one realistic bug injected into a copy of the RTL. The quick
detection suite (riscv-tests on core and SoC, 8 random co-sim seeds on the core,
4 random seeds on a tiny-cache SoC, and the directed tests) must catch it.

| # | Injected bug | Caught? | First caught by |
|---|---|---|---|
| M01 | EX/MEM -> EX forwarding path removed | killed | riscv-tests (core) |
| M02 | MEM/WB -> EX forwarding path removed | killed | riscv-tests (core) |
| M03 | CSR-use hazard not detected (only load-use) | killed | riscv-tests (core) |
| M04 | register-file write-through bypass missing (rs1) | killed | riscv-tests (core) |
| M05 | operands not re-captured while EX is stalled | killed | random co-sim |
| M06 | divider samples operands during a stall (real bug #2) | killed | random co-sim |
| M07 | BLTU uses a signed comparison | killed | riscv-tests (core) |
| M08 | C.SRAI expanded as SRLI | killed | riscv-tests (core) |
| M09 | MRET always re-enables interrupts | killed | random co-sim |
| M10 | stale fetch responses not dropped after a redirect | killed | riscv-tests (core) |
| M11 | straddling instruction takes upper half from wrong word | killed | riscv-tests (core) |
| M12 | minstret counted at WB instead of MEM (real bug #1) | killed | random co-sim |
| M13 | D-cache store->load bypass missing | killed | riscv-tests (SoC) |
| M14 | D-cache drops dirty lines on eviction (no write-back) | killed (after suite fix) | random co-sim (stress SoC) |
| M15 | FENCE.I does not invalidate the I-cache | killed | riscv-tests (SoC) |
| M16 | FENCE.I does not flush the D-cache | killed | riscv-tests (core) |

**Final score: 16/16 killed.**

**Round 1 scored 15/16.** M14 (the D-cache silently drops dirty lines on eviction) survived.
- Every SoC-level test in the quick suite fit inside the 4 KiB D-cache, so nothing was ever evicted.
- The constrained-random co-sim only ran on the cacheless core.
- **Fix:** add random co-sim on a stressed SoC (2 ways × 4 sets, 6-cycle memory) to the suite. M14 is now killed.

The full nightly regression (`make regress`) already included this configuration. The mutation run showed that the *quick* suite had a blind spot.
