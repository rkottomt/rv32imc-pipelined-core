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
- Training is registered, one cycle after EX, to keep the predictor write ports off the critical timing path.

### The tricky part: predictions + compressed code
The BTB is indexed by *fetch-word* address, but instructions can start at halfword 2 and 32-bit ones can **straddle two words**.
- **Normal entries** record the halfword (`off`) where the branch starts.
- **Straddling branches** are stored under the word where they *end*, with an `xe` flag. When the aligner builds a straddling instruction from words *h* and *h+1*, it takes the prediction from *h+1* and then drops both words.
  - *History*: the first version simply never installed straddling branches. Profiling CoreMark later showed this left ~half of all branches unpredictable (28% mispredict rate). The `xe` scheme cut it to 10% and raised IPC 11%. See `07_performance.md`.
- **Stale or aliased entries** can point at a halfword that is not an instruction boundary:
  - code was rewritten (self-modifying code + FENCE.I does not flush the BTB);
  - an `xe` entry reaches the head without its straddling owner.
  - The aligner detects this (`pmismatch`) and performs a **fixup**: it keeps the current word, clears the bogus prediction, drops everything fetched after it, and refetches sequentially.
  - This path is exercised by `sw/tests/bp_fixup.S`. Code coverage showed random tests never reached it.

### Why correctness never depends on the predictor
- Each instruction carries `pred_npc`, and EX compares it against the real next PC.
- So a bad prediction can never corrupt state. It can only cost a redirect (4 cycles: the redirect is registered for timing).
- That's why the predictor can use a speculative RAS without repair, and a non-speculative GHR, with no correctness risk.

## Interview Q&A
- **gshare vs bimodal?** Bimodal indexes by PC only. gshare XORs in global history, so the same branch gets different counters depending on the path taken to reach it. This captures correlated branches (e.g. `if (x) ...; if (x) ...`).
- **Why a separate RAS?** A BTB stores only one target per return instruction, but a function returns to many call sites. A stack matches the call/return nesting.
- **What happens on a BTB alias?** EX detects that the predicted NPC ≠ actual NPC, redirects, and retrains. Cost: 4 cycles.
