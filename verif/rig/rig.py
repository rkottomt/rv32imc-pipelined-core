#!/usr/bin/env python3
"""rig.py - constrained-random instruction generator (RIG) for RV32IMC.

Generates a self-checking-by-co-simulation assembly program: the program
itself doesn't know the right answers; the RTL trace is compared against the
ISS (verif/iss/compare.py), so *any* divergence in architectural state is
caught on the instruction where it first happens.

Constraints that keep programs well-formed:
  x31  = base pointer into a 4 KiB data region (never overwritten)
  x30  = loop counter for bounded backward loops
  x28/x29 = reserved for the trap handler
  x2 (sp), x9 = base pointers for c.lwsp/c.swsp and c.lw/c.sw
The first 64 bytes of the data region hold a pointer table (data
pointers + function pointers) that random stores never overwrite.
  x1   = link register, written only by calls into generated leaf functions
Everything else is fair game, with a bias towards a small "hot" register
set so read-after-write hazards at distance 1-3 happen constantly.

Usage: rig.py --seed N --length L -o prog.S [--irq]
"""
import argparse
import random

HOT_REGS = [5, 6, 7, 10, 11, 12]
ALL_REGS = [r for r in range(3, 28) if r != 9]
INTERESTING = [0, 1, 2, -1, -2, 0x7FFFFFFF, -0x80000000, 0x80000001 - (1 << 32), 0x55555555, 0x0000FFFF,
               0xFFFF, 0x8000, 0x7FFF, 31, 32, 33]

ALU_RR = ['add', 'sub', 'sll', 'slt', 'sltu', 'xor', 'srl', 'sra', 'or', 'and']
ALU_RI = ['addi', 'slti', 'sltiu', 'xori', 'ori', 'andi']
SHIFT_I = ['slli', 'srli', 'srai']
MULDIV = ['mul', 'mulh', 'mulhsu', 'mulhu', 'div', 'divu', 'rem', 'remu']
LOADS = [('lb', 1), ('lbu', 1), ('lh', 2), ('lhu', 2), ('lw', 4)]
STORES = [('sb', 1), ('sh', 2), ('sw', 4)]
BRANCHES = ['beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu']
CSRS_RW = ['mscratch', 'mtval', 'mcause']
CSRS_RO = ['mcycle', 'minstret', 'mhartid', 'misa', 'mstatus', 'mie', 'mip', 'mvendorid', 'cycle', 'instret',
           'mhpmcounter3', 'mhpmcounter4']


class Gen:
    def __init__(self, seed, length, irq):
        self.r = random.Random(seed)
        self.length = length
        self.irq = irq
        self.lines = []
        self.label_n = 0
        self.funcs = 0

    def reg(self, dst=False):
        r = self.r
        return r.choice(HOT_REGS) if r.random() < 0.7 else r.choice(ALL_REGS)

    def imm12(self):
        r = self.r
        return r.choice([0, 1, -1, 2047, -2048, r.randint(-2048, 2047), r.randint(-16, 16)])

    def label(self):
        self.label_n += 1
        return f"L{self.label_n}"

    def emit(self, s):
        self.lines.append("    " + s)

    # ------------------------------------------------------------------
    def one(self, depth=0, allow_ctrl=True):
        r = self.r
        k = r.random()
        if k < 0.22:
            self.emit(f"{r.choice(ALU_RR)} x{self.reg()}, x{self.reg()}, x{self.reg()}")
        elif k < 0.34:
            self.emit(f"{r.choice(ALU_RI)} x{self.reg()}, x{self.reg()}, {self.imm12()}")
        elif k < 0.40:
            self.emit(f"{r.choice(SHIFT_I)} x{self.reg()}, x{self.reg()}, {r.randint(0, 31)}")
        elif k < 0.43:
            self.emit(f"{r.choice(['lui', 'auipc'])} x{self.reg()}, {r.randint(0, 0xFFFFF)}")
        elif k < 0.47:
            self.emit(f"li x{self.reg()}, {r.choice(INTERESTING)}")
        elif k < 0.55:
            self.emit(f"{r.choice(MULDIV)} x{self.reg()}, x{self.reg()}, x{self.reg()}")
        elif k < 0.66:
            op, n = r.choice(LOADS)
            base = self.base_reg()
            self.emit(f"{op} x{self.reg()}, {self.mem_off(n, base != 31)}(x{base})")
        elif k < 0.75:
            op, n = r.choice(STORES)
            base = self.base_reg()
            self.emit(f"{op} x{self.reg()}, {self.mem_off(n, base != 31)}(x{base})")
        elif k < 0.79:
            self.compressed()
        elif k < 0.82:
            self.csr()
        elif k < 0.835:
            self.exception()
        elif k < 0.845:
            self.emit(r.choice(["fence", "fence.i", "wfi", "fence rw, rw"]))
        elif allow_ctrl and k < 0.93:
            self.fwd_branch(depth)
        elif allow_ctrl and k < 0.96 and depth == 0:
            self.loop()
        elif allow_ctrl and k < 0.985 and depth == 0:
            self.call()
        elif allow_ctrl and depth == 0 and k < 0.993:
            self.indirect_jump()
        elif allow_ctrl and depth == 0:
            self.link_use()
        else:
            self.emit(f"add x{self.reg()}, x{self.reg()}, x{self.reg()}")

    def base_reg(self):
        """Usually x31; sometimes a freshly computed or freshly loaded pointer,
        placed 0-2 instructions before use (address-generation hazards)."""
        r = self.r
        k = r.random()
        if k < 0.6:
            return 31
        b = r.choice(HOT_REGS)
        if k < 0.8:
            self.emit(f"addi x{b}, x31, {r.randrange(-256, 256, 4)}")
        else:   # pointer chase: load a data pointer from the protected table
            self.emit(f"lw x{b}, {r.randrange(0, 32, 4) - 2048}(x31)")
        for _ in range(r.choice([0, 0, 1, 2])):
            self.emit(f"{r.choice(ALU_RR)} x{r.choice([x for x in HOT_REGS if x != b])}, x{self.reg()}, x{self.reg()}")
        return b

    def mem_off(self, n, near=False):
        r = self.r
        if near:   # base points into the middle part of the data region
            return r.randrange(-128, 128, n)
        off = r.randrange(-2048 + 64, 2048 - 4, n)
        if r.random() < 0.06:          # occasionally misaligned -> trap
            off += r.randint(1, 3)
        return max(-2048, min(2047, off))

    def compressed(self):
        r = self.r
        cr = r.choice([8, 10, 11, 12, 13, 14, 15])   # c.* 3-bit register field (x9 reserved)
        cr2 = r.randint(8, 15)
        choices = [
            f"c.addi x{self.reg()}, {r.choice([1, -1, 31, -32, 5])}",
            f"c.li x{self.reg()}, {r.randint(-32, 31)}",
            f"c.mv x{self.reg()}, x{self.reg()}",
            f"c.add x{self.reg()}, x{self.reg()}",
            f"c.slli x{self.reg()}, {r.randint(1, 31)}",
            f"c.srli x{cr}, {r.randint(1, 31)}",
            f"c.srai x{cr}, {r.randint(1, 31)}",
            f"c.andi x{cr}, {r.randint(-32, 31)}",
            f"c.sub x{cr}, x{cr2}", f"c.xor x{cr}, x{cr2}", f"c.or x{cr}, x{cr2}", f"c.and x{cr}, x{cr2}",
            f"c.lui x{r.choice([5, 6, 7, 10, 11, 12, 13])}, {r.randint(1, 31)}",
            f"c.nop",
            f"c.lw x{cr}, {r.randrange(0, 128, 4)}(x9)",
            f"c.sw x{cr2}, {r.randrange(0, 128, 4)}(x9)",
            f"c.lwsp x{self.reg()}, {r.randrange(0, 256, 4)}(sp)",
            f"c.swsp x{self.reg()}, {r.randrange(0, 256, 4)}(sp)",
            f"c.addi4spn x{cr}, sp, {r.randrange(4, 1020, 4)}",
            "c.addi16sp sp, 32\n    c.addi16sp sp, -32",
        ]
        self.emit(r.choice(choices))

    def csr(self):
        r = self.r
        k = r.random()
        if k < 0.4:
            op = r.choice(['csrrw', 'csrrs', 'csrrc'])
            self.emit(f"{op} x{self.reg()}, {r.choice(CSRS_RW)}, x{self.reg()}")
        elif k < 0.6:
            op = r.choice(['csrrwi', 'csrrsi', 'csrrci'])
            self.emit(f"{op} x{self.reg()}, {r.choice(CSRS_RW)}, {r.randint(0, 31)}")
        elif k < 0.95:
            self.emit(f"csrr x{self.reg()}, {r.choice(CSRS_RO)}")
        else:
            # illegal: write to a read-only CSR / nonexistent CSR
            self.emit(r.choice([f"csrw mhartid, x{self.reg()}", "csrr x5, 0x7c0"]))

    def exception(self):
        r = self.r
        self.emit(r.choice(["ecall", "ebreak", ".option push\n    .option norvc\n    ebreak\n    .option pop",
                            ".word 0x00000000", ".word 0xffffffff", ".half 0x0000",
                            ".word 0x0000700b", "c.ebreak"]))

    def fwd_branch(self, depth):
        r = self.r
        tgt = self.label()
        k = r.random()
        if k < 0.75:
            self.emit(f"{r.choice(BRANCHES)} x{self.reg()}, x{self.reg()}, {tgt}")
        elif k < 0.85:
            self.emit(f"{r.choice(['c.beqz', 'c.bnez'])} x{r.randint(8, 15)}, {tgt}")
        else:
            self.emit(f"j {tgt}")
        for _ in range(r.randint(0, 6)):
            self.one(depth + 1, allow_ctrl=depth < 2)
        self.lines.append(f"{tgt}:")

    def loop(self):
        r = self.r
        top = self.label()
        self.emit(f"li x30, {r.randint(1, 12)}")
        self.lines.append(f"{top}:")
        for _ in range(r.randint(1, 8)):
            self.one(1, allow_ctrl=r.random() < 0.5)
        self.emit("addi x30, x30, -1")
        self.emit(f"bnez x30, {top}")

    def call(self):
        r = self.r
        self.funcs += 1
        if r.random() < 0.3:     # call through a function pointer from the table
            b = r.choice(HOT_REGS)
            self.emit(f"lw x{b}, {32 + 4 * r.randrange(8) - 2048}(x31)")
            for _ in range(r.choice([0, 1, 2])):
                self.emit(f"add x{r.choice([x for x in HOT_REGS if x != b])}, x{self.reg()}, x{self.reg()}")
            if r.random() < 0.5:
                self.emit(f".option push\n    .option norvc\n    jalr x1, 0(x{b})\n    .option pop")
            else:
                self.emit(f"jalr x{b}")
        else:
            self.emit(f"call func{self.funcs}")

    def indirect_jump(self):
        tgt = self.label()
        r = self.r
        reg = r.choice(HOT_REGS)
        self.emit(f"la x{reg}, {tgt}")
        for _ in range(r.choice([0, 0, 1, 2])):
            self.emit(f"xor x{r.choice([x for x in HOT_REGS if x != reg])}, x{self.reg()}, x{self.reg()}")
        self.emit(r.choice([f"jr x{reg}", f"c.jr x{reg}",
                            f".option push\n    .option norvc\n    jalr x0, 0(x{reg})\n    .option pop"]))
        self.emit("nop")
        self.lines.append(f"{tgt}:")

    def link_use(self):
        """jal/jalr writing a general register whose value is then consumed
        as data (link -> ALU / branch / address / store-data / mul / CSR)."""
        r = self.r
        tgt = self.label()
        b = r.choice(HOT_REGS)
        self.emit(f"jal x{b}, {tgt}" if r.random() < 0.7 else f"{tgt}a: auipc x{b}, %pcrel_hi({tgt})\n    jalr x{b}, %pcrel_lo({tgt}a)(x{b})")
        self.emit("nop")
        self.lines.append(f"{tgt}:")
        for _ in range(r.choice([0, 1, 2])):
            self.emit(f"or x{r.choice([x for x in HOT_REGS if x != b])}, x{self.reg()}, x{self.reg()}")
        d = r.choice([x for x in HOT_REGS if x != b])
        nxt = self.label()
        self.emit(r.choice([f"add x{d}, x{b}, x{self.reg()}", f"bne x{b}, x{b}, {nxt}",
                            f"lw x{d}, 0(x{b})", f"sw x{b}, {self.mem_off(4)}(x31)",
                            f"mul x{d}, x{b}, x{self.reg()}", f"csrw mscratch, x{b}"]))
        self.lines.append(f"{nxt}:")

    # ------------------------------------------------------------------
    def program(self):
        r = self.r
        out = []
        out.append("""    .section .text.init
    .globl _start
_start:
    la x28, trap_handler
    csrw mtvec, x28
    la x31, data + 2048
    la x9, data + 1024
    la sp, data + 1536""")
        for reg in range(3, 28):
            if reg != 9:
                out.append(f"    li x{reg}, {r.choice(INTERESTING + [r.randint(-2**31, 2**31 - 1)])}")
        if self.irq:
            out.append("    li x28, 0x888\n    csrw mie, x28\n    csrsi mstatus, 8")
        self.lines = []
        while len(self.lines) < self.length:
            self.one()
        out += self.lines
        out.append("""    # ---- end of test: write 1 ("pass") to the simulation controller
    # (x30/x31 are not used by the trap handler, so an interrupt arriving
    # between these instructions cannot corrupt the exit value)
    li x31, 0x10002000
    li x30, 1
    sw x30, 0(x31)
1:  j 1b
""")
        # leaf functions (exercise call/return prediction)
        for f in range(1, self.funcs + 1):
            out.append(f"func{f}:")
            self.lines = []
            for _ in range(r.choice([0, 1, 2, 4, 6])):
                self.one(3, allow_ctrl=False)
            out += self.lines
            out.append("    ret" if r.random() < 0.5 else "    c.jr x1")
        out.append("""
    # ---- trap handler: skip the faulting instruction (exceptions) or just
    # return (interrupts). Uses only x28/x29.
    .align 2
trap_handler:
    csrr x28, mcause
    bltz x28, 2f
    csrr x28, mepc
    lhu x29, 0(x28)
    andi x29, x29, 3
    addi x28, x28, 2
    addi x29, x29, -3
    bnez x29, 1f
    addi x28, x28, 2
1:  csrw mepc, x28
2:  mret

    .data
    .align 4
data:
""")
        # pointer table: 8 data pointers then 8 function pointers
        nf = max(1, self.funcs)
        out.append("    .word " + ", ".join(f"data + {r.randrange(512, 3584, 4)}" for _ in range(8)))
        out.append("    .word " + ", ".join(f"func{r.randint(1, nf)}" for _ in range(8)))
        words = [r.getrandbits(32) for _ in range(1024 - 16)]
        for i in range(0, len(words), 8):
            out.append("    .word " + ", ".join(f"0x{w:08x}" for w in words[i:i + 8]))
        return "\n".join(out) + "\n"


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--length', type=int, default=2000)
    ap.add_argument('--irq', action='store_true')
    ap.add_argument('-o', '--out', required=True)
    a = ap.parse_args()
    open(a.out, 'w').write(Gen(a.seed, a.length, a.irq).program())
