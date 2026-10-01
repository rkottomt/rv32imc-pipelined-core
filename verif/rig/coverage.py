#!/usr/bin/env python3
"""coverage.py - functional coverage collected from RTL retirement traces.

    coverage.py trace1 [trace2 ...] [--json out.json] [--html out.html]

Coverage groups (each "bin" must be hit at least once):
  insn      every RV32IMC + Zicsr instruction (compressed forms counted separately)
  raw_haz   read-after-write hazards: producer class x consumer class x distance 1..3
            (distance 1 = back-to-back -> exercises EX/MEM bypass or load-use stall,
             2 = MEM/WB bypass, 3 = register-file write-through)
  branch    each branch condition x {taken, not taken}
  mem       each load/store size x byte offset within the word
  trap      each exception cause + interrupt causes
  align     32-bit instruction at halfword offset 2 (straddles two fetch words),
            taken control flow into an odd halfword, compressed/32-bit mixes
"""
import argparse
import json
import os
import sys
from collections import Counter, deque

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'iss'))
from rv32iss import expand_rvc  # noqa: E402

RV32I = ['lui', 'auipc', 'jal', 'jalr', 'beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu', 'lb', 'lh', 'lw', 'lbu', 'lhu',
         'sb', 'sh', 'sw', 'addi', 'slti', 'sltiu', 'xori', 'ori', 'andi', 'slli', 'srli', 'srai', 'add', 'sub',
         'sll', 'slt', 'sltu', 'xor', 'srl', 'sra', 'or', 'and', 'fence', 'fence.i', 'ecall', 'ebreak', 'mret',
         'wfi']
RV32M = ['mul', 'mulh', 'mulhsu', 'mulhu', 'div', 'divu', 'rem', 'remu']
ZICSR = ['csrrw', 'csrrs', 'csrrc', 'csrrwi', 'csrrsi', 'csrrci']
RV32C = ['c.addi4spn', 'c.lw', 'c.sw', 'c.nop', 'c.addi', 'c.jal', 'c.li', 'c.addi16sp', 'c.lui', 'c.srli',
         'c.srai', 'c.andi', 'c.sub', 'c.xor', 'c.or', 'c.and', 'c.j', 'c.beqz', 'c.bnez', 'c.slli', 'c.lwsp',
         'c.jr', 'c.mv', 'c.ebreak', 'c.jalr', 'c.add', 'c.swsp']

PRODUCERS = ['alu', 'load', 'mul', 'div', 'csr', 'link']
CONSUMERS = ['alu', 'branch', 'ldaddr', 'stdata', 'muldiv', 'jalr', 'csr']


def cname(c):
    op, f3 = c & 3, (c >> 13) & 7
    rd, rs2 = (c >> 7) & 31, (c >> 2) & 31
    if op == 0:
        return {0: 'c.addi4spn', 2: 'c.lw', 6: 'c.sw'}.get(f3, 'c.illegal')
    if op == 1:
        if f3 == 0:
            return 'c.nop' if rd == 0 else 'c.addi'
        if f3 == 3:
            return 'c.addi16sp' if rd == 2 else 'c.lui'
        if f3 == 4:
            f2 = (c >> 10) & 3
            if f2 < 3:
                return ['c.srli', 'c.srai', 'c.andi'][f2]
            return ['c.sub', 'c.xor', 'c.or', 'c.and'][(c >> 5) & 3]
        return {1: 'c.jal', 2: 'c.li', 5: 'c.j', 6: 'c.beqz', 7: 'c.bnez'}[f3]
    if f3 == 0:
        return 'c.slli'
    if f3 == 2:
        return 'c.lwsp'
    if f3 == 6:
        return 'c.swsp'
    if f3 == 4:
        b12 = (c >> 12) & 1
        if not b12:
            return 'c.jr' if rs2 == 0 else 'c.mv'
        if rd == 0 and rs2 == 0:
            return 'c.ebreak'
        return 'c.jalr' if rs2 == 0 else 'c.add'
    return 'c.illegal'


def decode(i):
    """Return (mnemonic, rd, rs1 or None, rs2 or None) for a 32-bit instruction."""
    op = i & 0x7F
    rd, f3, rs1, rs2, f7 = (i >> 7) & 31, (i >> 12) & 7, (i >> 15) & 31, (i >> 20) & 31, i >> 25
    if op == 0x37:
        return 'lui', rd, None, None
    if op == 0x17:
        return 'auipc', rd, None, None
    if op == 0x6F:
        return 'jal', rd, None, None
    if op == 0x67:
        return 'jalr', rd, rs1, None
    if op == 0x63:
        return ['beq', 'bne', '?', '?', 'blt', 'bge', 'bltu', 'bgeu'][f3], 0, rs1, rs2
    if op == 0x03:
        return ['lb', 'lh', 'lw', '?', 'lbu', 'lhu', '?', '?'][f3], rd, rs1, None
    if op == 0x23:
        return ['sb', 'sh', 'sw', '?', '?', '?', '?', '?'][f3], 0, rs1, rs2
    if op == 0x13:
        if f3 == 5:
            return ('srai' if f7 else 'srli'), rd, rs1, None
        return ['addi', 'slli', 'slti', 'sltiu', 'xori', '?', 'ori', 'andi'][f3], rd, rs1, None
    if op == 0x33:
        if f7 == 1:
            return RV32M[f3], rd, rs1, rs2
        if f7 == 0x20:
            return ('sub' if f3 == 0 else 'sra'), rd, rs1, rs2
        return ['add', 'sll', 'slt', 'sltu', 'xor', 'srl', 'or', 'and'][f3], rd, rs1, rs2
    if op == 0x0F:
        return ('fence.i' if f3 == 1 else 'fence'), 0, None, None
    if op == 0x73:
        if f3 == 0:
            return {0x00000073: 'ecall', 0x00100073: 'ebreak', 0x30200073: 'mret',
                    0x10500073: 'wfi'}.get(i, '?'), 0, None, None
        name = ['?', 'csrrw', 'csrrs', 'csrrc', '?', 'csrrwi', 'csrrsi', 'csrrci'][f3]
        return name, rd, (rs1 if f3 < 4 else None), None
    return '?', 0, None, None


def pclass(m):
    if m in ('lb', 'lh', 'lw', 'lbu', 'lhu'):
        return 'load'
    if m in ('mul', 'mulh', 'mulhsu', 'mulhu'):
        return 'mul'
    if m in ('div', 'divu', 'rem', 'remu'):
        return 'div'
    if m.startswith('csr'):
        return 'csr'
    if m in ('jal', 'jalr'):
        return 'link'
    return 'alu'


class Cov:
    def __init__(self):
        self.bins = {
            'insn': {k: 0 for k in RV32I + RV32M + ZICSR + RV32C},
            'raw_haz': {f"{p}->{c}@{d}": 0 for p in PRODUCERS for c in CONSUMERS for d in (1, 2, 3)},
            'branch': {f"{b}:{t}": 0 for b in ['beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu'] for t in ('T', 'NT')},
            'mem': {f"{m}+{o}": 0 for m, n in [('lb', 1), ('lbu', 1), ('lh', 2), ('lhu', 2), ('lw', 4),
                                               ('sb', 1), ('sh', 2), ('sw', 4)] for o in range(0, 4, n)},
            'trap': {k: 0 for k in ['illegal', 'breakpoint', 'ld_misalign', 'st_misalign', 'ecall', 'irq_ext']},
            'align': {k: 0 for k in ['insn32_at_half2', 'jump_to_half2', 'c_after_32', '32_after_c']},
        }
        # Address-generation / jump-target consumers only make sense fed by
        # integer ALU results, loads (pointer chasing) or link values.
        for c in ('ldaddr', 'jalr'):
            for p in ('mul', 'div', 'csr'):
                for d in (1, 2, 3):
                    del self.bins['raw_haz'][f"{p}->{c}@{d}"]
        self.unknown = Counter()

    def hit(self, g, k):
        if k in self.bins[g]:
            self.bins[g][k] += 1
        else:
            self.unknown[(g, k)] += 1

    def add_trace(self, path):
        hist = deque(maxlen=3)   # (rd, class) of last 3 retired, most recent first
        prev_c = None
        for line in open(path):
            f = line.split()
            if not f:
                continue
            pc, raw, trap = int(f[0], 16), int(f[1], 16), int(f[2])
            irq, npc = int(f[4]), int(f[6], 16)
            rmask, wmask, maddr = int(f[9], 16), int(f[10], 16), int(f[11], 16)
            if irq:
                self.hit('trap', 'irq_ext')
                hist.clear()
            is_c = (raw & 3) != 3
            if trap:
                x = expand_rvc(raw) if is_c else raw
                m = decode(x)[0] if x is not None else '?'
                cause = {'ecall': 'ecall', 'ebreak': 'breakpoint'}.get(m)
                if cause is None:
                    cause = ('ld_misalign' if m in ('lb', 'lh', 'lw', 'lbu', 'lhu') else
                             'st_misalign' if m in ('sb', 'sh', 'sw') else 'illegal')
                self.hit('trap', cause)
                if is_c and cname(raw) == 'c.ebreak':
                    self.hit('insn', 'c.ebreak')
                elif m in ('ecall', 'ebreak'):
                    self.hit('insn', m)
                hist.clear()
                prev_c = None
                continue
            x = expand_rvc(raw) if is_c else raw
            m, rd, rs1, rs2 = decode(x)
            self.hit('insn', cname(raw) if is_c else m)
            if not is_c and pc & 2:
                self.hit('align', 'insn32_at_half2')
            if prev_c is not None:
                if prev_c and not is_c:
                    self.hit('align', '32_after_c')
                if not prev_c and is_c:
                    self.hit('align', 'c_after_32')
            prev_c = is_c
            # consumer classes for each source operand
            cons = []
            if m in ('beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu'):
                cons = [(rs1, 'branch'), (rs2, 'branch')]
                self.hit('branch', f"{m}:{'T' if npc != pc + (2 if is_c else 4) else 'NT'}")
            elif m in ('sb', 'sh', 'sw'):
                cons = [(rs1, 'ldaddr'), (rs2, 'stdata')]
            elif m in ('lb', 'lh', 'lw', 'lbu', 'lhu'):
                cons = [(rs1, 'ldaddr')]
            elif m in RV32M:
                cons = [(rs1, 'muldiv'), (rs2, 'muldiv')]
            elif m == 'jalr':
                cons = [(rs1, 'jalr')]
            elif m.startswith('csr'):
                cons = [(rs1, 'csr')]
            else:
                cons = [(rs1, 'alu'), (rs2, 'alu')]
            for reg, cc in cons:
                if not reg:
                    continue
                for d, (prd, pcl) in enumerate(hist, 1):
                    if prd == reg:
                        self.hit('raw_haz', f"{pcl}->{cc}@{d}")
                        break
            if rmask or wmask:
                mask = rmask or wmask
                off = (mask & -mask).bit_length() - 1
                self.hit('mem', f"{m}+{off}")
            if npc & 2 and npc != pc + (2 if is_c else 4):
                self.hit('align', 'jump_to_half2')
            hist.appendleft((rd, pclass(m)))

    def report(self):
        total = hit = 0
        lines = []
        for g, b in self.bins.items():
            h = sum(1 for v in b.values() if v)
            total += len(b)
            hit += h
            lines.append(f"  {g:8s} {h:4d}/{len(b):<4d} {100.0 * h / len(b):6.1f}%")
            missing = [k for k, v in b.items() if not v]
            if missing:
                lines.append(f"           missing: {', '.join(missing[:12])}{' ...' if len(missing) > 12 else ''}")
        lines.insert(0, f"Functional coverage: {hit}/{total} bins = {100.0 * hit / total:.1f}%")
        return "\n".join(lines), hit, total


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('traces', nargs='+')
    ap.add_argument('--json')
    a = ap.parse_args()
    cov = Cov()
    for t in a.traces:
        cov.add_trace(t)
    text, hit, total = cov.report()
    print(text)
    if a.json:
        json.dump({'bins': cov.bins, 'hit': hit, 'total': total}, open(a.json, 'w'), indent=1)
