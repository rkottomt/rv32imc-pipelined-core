# 04 — Caches and SoC

## SoC block diagram
```
 rv_core --ibus--> I-cache --+
                             +--> arbiter --> decoder --+--> RAM (BRAM, optional DRAM-like latency)
 rv_core --dbus--> D-cache --+    (1 outstanding)        +--> periph: CLINT timer, UART, GPIO, SIMCTRL
```

| Region | Address | Notes |
|---|---|---|
| RAM | `0x0000_0000` (64 KiB) | cacheable, boot address |
| CLINT | `0x0200_0000` | `msip` (+0), `mtimecmp` (+0x4000), `mtime` (+0xBFF8) → timer/software interrupts |
| UART | `0x1000_0000` | TX data (+0), status (+4). Real 8N1 shifter on the FPGA, `$write` in simulation |
| GPIO | `0x1000_1000` | 8 LEDs |
| SIMCTRL | `0x1000_2000` | "tohost": write 1 = pass, `(code<<1)\|1` = fail |

## Bus protocol (one protocol everywhere)
- **Request**: `valid/ready` handshake carrying `addr, we, be, wdata`.
- **Response**: `resp_valid` + `rdata`. Exactly one response per accepted request, in order. Writes get a response too (an acknowledgement).
- The core's instruction side can have several requests in flight (pipelined fetch). The data side and the system bus have one.
- *Why simple and not AXI?* It keeps the focus on the micro-architecture. An AXI4-Lite bridge would be a mechanical addition (good "future work" talking point).

## I-cache (`rtl/cache/rv_icache.v`)
- **Organization**: 2-way set-associative, 128 sets × 16-byte lines = 4 KiB, LRU replacement (1 bit per set).
- **Tags**: in LUT RAM (asynchronous read).
- **Data**: in block RAM (synchronous read).
- **Pipelined hits**:
  - Cycle t: accept the request and start the BRAM read.
  - Cycle t+1: compare tags and respond. A new request can also be accepted in this cycle, so straight-line code streams one word per cycle.
- **Miss**: stop accepting, fetch the 4 words of the line, capture the requested word on the way, install the tag, respond.
- **FENCE.I** invalidates all lines in 1 cycle (valid bits are flip-flops).
  - Subtle case: a refill *already in flight* when FENCE.I arrives may contain stale data, so it is not installed (`kill_refill`).

## D-cache (`rtl/cache/rv_dcache.v`)
- **Policy**: 2-way, 4 KiB, **write-back + write-allocate**, LRU, dirty bit per line.
- **Hit**: responds the cycle after the request and can accept the next request in that same cycle.
- **Store hit**: writes the BRAM with byte enables and sets the line's dirty bit.
- **Store→load bypass**: a load issued right after a store to the same word would read the BRAM in the same cycle the store writes it, and get *old* data (read-during-write). The cache keeps the last store's address, byte enables and data, and merges them into the next lookup.
- **Miss**: if the victim is dirty, write back its 4 words, then refill 4 words, then *replay* the lookup, which now hits. Replay reuses the hit path for stores, so there's no special "store miss" logic.
- **Uncached**: anything outside RAM (MMIO) bypasses the arrays.
- **Flush (for FENCE.I)**: walks every set and way and writes back dirty lines.
  - The flush request is *accepted only after the flush finishes*. The core cannot complete FENCE.I, and therefore cannot refetch, until memory holds the new code.

## Self-modifying code: why FENCE.I touches both caches
1. A store to the code area goes into the **D-cache**, not memory. Write-back cache!
2. FENCE.I in MEM sends a *flush* request on the data bus. The D-cache writes all dirty lines to RAM.
3. When it completes, the core invalidates the **I-cache** and redirects fetch to the next instruction.
4. Instruction fetches miss and read the *new* code from RAM.

The official `rv32ui-fence_i` test checks this end-to-end and passes on the SoC.

## Verification of the memory system
- **Unit level (cocotb, `verif/cocotb/test_units.py`)**: D-cache with only 4 sets, 5000 random loads/stores/flushes.
  - A memory model with random ready and latency.
  - Every load checked against a shadow memory.
  - After the final flush, backing memory must equal the shadow.
- **System level**: the constrained-random co-sim suite runs on the full SoC configured with **tiny caches** (2 ways × 4 sets) and **6-cycle RAM latency**.
  - About 1,000 I-misses, 500 D-misses and 200 dirty write-backs per program, all matching the ISS.
  - Configured through Verilog parameters at build time: `make sim-soc SOC_TAG=_stress SOC_DEFS="-GRAM_LATENCY=6 -GCACHE_SET_BITS=2"`.
- **Exhaustive**: all 49,152 16-bit compressed encodings checked against the ISS expander.
- **M-unit**: 6,600 operations, including the full corner-value cross product (0, ±1, INT_MIN, INT_MAX, …).

## Design Q&A
- **Write-back vs write-through?** Write-back sends only evicted dirty lines to memory, which means far less bus traffic for stack- and loop-heavy code. The cost is dirty-line handling and a flush operation for coherence (FENCE.I, DMA).
- **Why replay after refill instead of serving the miss directly?** One code path (the hit path) handles both loads and stores. The extra cycle is negligible next to a refill.
- **Read-during-write hazard?** Block RAMs return old data when reading the address being written that cycle, so the cache forwards the last store. A classic FPGA-specific bug. It's documented in the BRAM primitive's datasheet as `READ_FIRST` mode.
- **Why does the arbiter prioritize the D-cache?** The D-side stalls the whole pipeline (MEM/WB). The I-side has a 4-entry fetch queue to absorb delay.
