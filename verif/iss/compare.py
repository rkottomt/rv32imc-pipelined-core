#!/usr/bin/env python3
"""compare.py - lock-step comparison of an RTL retirement trace against the ISS.

    compare.py <elf> <trace> [--max-errors N] [--quiet]

Every record the RTL retired is replayed on the ISS; pc, instruction, trap,
next pc, destination register and value, and memory access (address + byte
masks) must all match. Asynchronous interrupts are injected into the ISS
exactly where the RTL took them (records flagged dbg_irq).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32iss import ISS, Memory  # noqa: E402

FIELDS = ('pc', 'insn', 'trap', 'pc_wdata', 'rd', 'rd_wdata', 'rmask', 'wmask', 'maddr')


def parse(line):
    f = line.split()
    return dict(pc=int(f[0], 16), insn=int(f[1], 16), trap=int(f[2]), intr=int(f[3]),
                irq=int(f[4]), irq_cause=int(f[5]), pc_wdata=int(f[6], 16), rd=int(f[7]),
                rd_wdata=int(f[8], 16), rmask=int(f[9], 16), wmask=int(f[10], 16), maddr=int(f[11], 16))


def run(elf, trace, max_errors=1, quiet=False):
    mem = Memory()
    entry, _ = mem.load_elf(elf)
    iss = ISS(mem, entry)
    errors = n = 0
    history = []
    with open(trace) as fh:
        for line in fh:
            if not line.strip():
                continue
            d = parse(line)
            if d['irq']:
                iss.take_interrupt(d['irq_cause'])
            r = iss.step(dut_rd_wdata=d['rd_wdata'])
            exp = {k: getattr(r, k) for k in FIELDS}
            # a load/CSR whose value came from the DUT (MMIO, counters) still
            # needs matching rd; nothing else to special-case.
            bad = [k for k in FIELDS if exp[k] != d[k]]
            history.append((d, r))
            history = history[-8:]
            n += 1
            if bad:
                errors += 1
                print(f"MISMATCH at retirement #{n}: fields {bad}")
                for hd, hr in history[:-1]:
                    print(f"   ok  : {hr}")
                print(f"   ISS : {r}")
                print("   RTL : " + " ".join(f"{k}={d[k]:x}" for k in FIELDS))
                if errors >= max_errors:
                    break
    if not quiet or errors:
        print(f"compare: {n} instructions checked, {errors} mismatches")
    return errors == 0 and n > 0


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('elf')
    ap.add_argument('trace')
    ap.add_argument('--max-errors', type=int, default=1)
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args()
    sys.exit(0 if run(a.elf, a.trace, a.max_errors, a.quiet) else 1)
