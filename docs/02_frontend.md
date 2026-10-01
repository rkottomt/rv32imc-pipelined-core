# 02 — Front End: Fetch, Compressed Instructions, Branch Prediction

File: `rtl/core/rv_frontend.v`

## Fetch queue
- IF issues one **word-aligned** 32-bit request per cycle while the 4-entry queue has room. Each request reserves a slot, so in-flight requests count against capacity.
- Responses arrive in order and fill the slots.
- **On a redirect** (mispredict or trap), all slots are dropped. Because requests are already in flight, a `drop` counter remembers how many future responses are stale and discards them as they arrive.
- This is the standard way to flush a pipelined bus you cannot cancel.

## The aligner (RVC support)
- Instructions are 16 or 32 bits, and 32-bit ones may start at offset +2 inside a word, **straddling two words**.
- The aligner tracks `pos` (are we at halfword 0 or 2 of the head word?):

| Situation | Action |
|---|---|
| 16-bit instr at pos 0 | emit, move to pos 2 (keep word) |
| 16-bit instr at pos 2 | emit, pop word |
| 32-bit instr at pos 0 | emit whole word, pop |
| 32-bit instr at pos 2 | **straddle**: combine `next[15:0]:head[31:16]`, needs both words, pop, next word starts at pos 2 |

- A jump to an address with bit 1 set records `start=1` in the slot, so decode begins at halfword 2.

## Branch prediction (looked up at *fetch* time, zero-bubble for correct taken predictions)

| Structure | Size | Purpose |
|---|---|---|
| BTB | 64 entries, direct-mapped by fetch-word address, full tag | "Is there a taken control-flow instruction in this word, at which halfword, and where does it go?" Also stores its type (cond / jump / call / return) and whether it is compressed. |
| gshare BHT | 256 × 2-bit saturating counters, index = `PC[9:2] XOR GHR` | Direction for conditional branches. The global history register captures correlation between branches. |
| RAS | 4-entry return address stack | Calls push the return address and returns pop it, so function returns predict correctly even when called from many sites. |

### Training
- Training happens in EX and is non-speculative.
- **Conditional branches**: update the counter at the index computed at fetch time. The index travels with the instruction, so training hits the same counter that made the prediction.
- **Taken control flow**: written into the BTB. The type is classified using the RISC-V calling-convention hint: `rd` is `x1`/`x5` means call; `jalr x0, 0(x1/x5)` means return.

### The tricky part: predictions + compressed code
- The BTB is indexed by *word* address, but instructions can start mid-word. Several things can make a prediction point at a halfword that is not actually an instruction boundary:
  - jumping into the middle of a word;
  - a straddling instruction covering the predicted slot;
  - aliasing.
- The aligner detects this (`pmismatch`) and performs a **fixup**: it keeps the current word, drops the bogus prediction and everything fetched after it, and refetches sequentially.
- 32-bit branches that straddle words are never installed in the BTB.
- The cost of a fixup is a few cycles, and it is rare.

### Why correctness never depends on the predictor
- Each instruction carries `pred_npc`, and EX compares it against the real next PC.
- So a bad prediction can never corrupt state. It can only cost a 3-cycle redirect.
- That's why the predictor can use a speculative RAS without repair, and a non-speculative GHR, with no correctness risk.

## Interview Q&A
- **gshare vs bimodal?** Bimodal indexes by PC only. gshare XORs in global history, so the same branch gets different counters depending on the path taken to reach it. This captures correlated branches (e.g. `if (x) ...; if (x) ...`).
- **Why a separate RAS?** A BTB stores only one target per return instruction, but a function returns to many call sites. A stack matches the call/return nesting.
- **What happens on a BTB alias?** EX detects that the predicted NPC ≠ actual NPC, redirects, and retrains. Cost: 3 cycles.
