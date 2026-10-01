# 01 — Core Microarchitecture

> Study goal: be able to draw the pipeline on a whiteboard and explain how
> every hazard is handled.

## The ISA in one paragraph
**RV32IMC + Zicsr, machine mode only.**
- **I**: 32-bit integer base (ALU ops, loads/stores, branches, jumps).
- **M**: multiply/divide.
- **C**: 16-bit compressed encodings of common instructions (~25–30% smaller code).
- **Zicsr**: control/status registers (CSRs) for traps, interrupts and counters.

## Pipeline (5 stages)

```
          +-----------------------------+
 IF       | fetch PC -> I-bus request   |<-- BTB / gshare / RAS predict next PC
          +--------------+--------------+
                         v  (fetch queue, 4 words)
 ID       aligner -> RVC expand -> decode -> regfile read -> hazard check
                         v  ID/EX
 EX       forwarding muxes -> ALU / MUL / DIV(iterative) -> branch resolve
                         |                      \__ mispredict? redirect IF
                         v  EX/MEM
 MEM      D-bus request | CSR read/write | TRAP / IRQ / MRET commit point
                         v  MEM/WB
 WB       load align+sign-extend -> regfile write -> retire (RVFI trace)
```

| Stage | File | Key job |
|---|---|---|
| IF | `rtl/core/rv_frontend.v` | Pipelined fetch, branch prediction, 4-entry fetch queue |
| ID | `rv_rvc_expand.v`, `rv_decode.v`, `rv_regfile.v` | 16→32 expansion, control decode, operand read |
| EX | `rv_alu.v`, `rv_muldiv.v` | Compute, resolve branches, check misalignment |
| MEM | `rv_csr.v` | Memory request, CSRs, exceptions/interrupts |
| WB | in `rv_core.v` | Write-back and retirement |

## Hazards, and how each is handled

**1. RAW data hazard: forwarding (bypassing).**
- An instruction in EX gets its operands from the youngest in-flight producer:
  1. the EX/MEM register (instruction one ahead);
  2. otherwise the WB value (two ahead);
  3. otherwise the value read from the register file in ID.
- The register file also has *write-through*: a read in ID returns the value being written in WB that same cycle. Three instructions ahead is therefore covered too.

**2. Load-use hazard: 1-cycle stall.**
- Load data only arrives in WB, so an instruction directly after a load that uses its result is held in ID for one cycle.
- CSR reads work the same way, because CSRs are accessed in MEM. The code calls these "late" results (`ex_late`).

**3. Control hazards: predict, then verify in EX.**
- Every instruction carries the *predicted* next PC (`pred_npc`).
- EX computes the real next PC. On a mismatch it flushes the two younger stages (ID and the fetch queue) and redirects fetch.
- The mispredict penalty is 3 cycles.
- Because *every* instruction is checked, a wrong prediction (even a stale or aliased BTB entry on a non-branch) can only cost time, never correctness.

**4. Structural / variable latency: stalls propagate backwards.**
- `stall_wb`: a load/store is waiting for its bus response.
- `stall_mem`: `stall_wb`, or the data bus is not ready to accept the request.
- `stall_ex`: `stall_mem`, or the divider is busy (about 33 cycles).
- `stall_id`: `stall_ex`, or a load-use hazard.

**The operand-capture subtlety** (a good interview story):
- If EX is stalled while MEM is stalled and WB keeps draining, the producer EX was forwarding from can *leave* the pipeline.
- Fix: while EX is stalled, it re-latches its forwarded operands every cycle (`ex_rs1_val <= ex_a_reg`), so the correct value is never lost.

## Precise exceptions and interrupts
- MEM is the single **commit point**. When an instruction in MEM has an exception (illegal instruction, ECALL, EBREAK, misaligned load/store, or an illegal CSR access) or an interrupt is pending:
  - every *older* instruction is already in WB and will complete;
  - every *younger* instruction (EX, ID, fetch queue) is flushed;
  - the instruction itself does not write anything; `mepc`, `mcause`, `mtval` and `mstatus` are updated and fetch is redirected to `mtvec`.
- CSR reads and writes and MRET also happen in MEM, so they are naturally ordered with traps.
- `minstret` increments at MEM too. An instruction that leaves MEM without trapping is guaranteed to retire.
  - *Bug story:* this originally counted in WB, so a `csrr minstret` saw a count that was one instruction behind. The official `instret_overflow` test caught it.

## M extension
- **MUL\***: single-cycle 33×33 signed multiply. The extra bit handles signed/unsigned variants uniformly, and it maps onto FPGA DSP blocks.
- **DIV/REM**: radix-2 *restoring* divider, one quotient bit per cycle (32 cycles plus setup).
  - Signs are stripped first and re-applied at the end.
  - Divide-by-zero follows the spec: quotient = all 1s, remainder = dividend.
  - Overflow (−2³¹ / −1) falls out naturally.

## Why "decoupled" fetch?
- The fetch unit runs ahead of decode, buffering up to 4 words. Bus latency or a decode stall is absorbed by the queue rather than stalling the whole machine.
- It also makes RVC (compressed) support clean: the aligner simply consumes 16-bit "parcels" from the word stream. See `02_frontend.md`.

## Interview Q&A
- **Why trap in MEM and not EX?** EX hasn't yet seen the result of older instructions' memory access or CSR side effects. MEM is the last point before state is updated, so committing there keeps exceptions precise with a single flush point.
- **Why can't the load result be forwarded to EX one cycle later without a stall?** The data bus responds at the end of MEM at the earliest (synchronous RAM / cache), so the value exists in WB.
- **What is the CPI cost of each hazard?** Load-use: 1 cycle. Mispredict: 3 cycles. DIV: about 33 cycles. Taken branch correctly predicted by the BTB: 0 cycles.
