"""rv32iss.py - Golden reference model (instruction set simulator) for RV32IMC_Zicsr, M-mode.

Written independently from the RTL, straight from the ISA spec. Used to check
the RTL instruction-by-instruction: every retirement record produced by the
Verilator testbench is compared with the record the ISS produces for the same
instruction (see compare.py).

Non-deterministic state (cycle counters, MMIO reads, mip) is synchronised from
the DUT trace, the same technique Spike-based co-simulation flows use.
"""
import struct

MASK = 0xFFFFFFFF


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def u32(v):
    return v & MASK


def s32(v):
    return sext(v, 32)


class Trap(Exception):
    def __init__(self, cause, tval=0):
        super().__init__(cause)
        self.cause, self.tval = cause, tval


# --------------------------------------------------------------------------
# RVC expansion (spec section "C" - RVC instruction listings)
def _r(f7, rs2, rs1, f3, rd, op=0x33):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _i(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _s(imm, rs2, rs1, f3):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | 0x23


def _b(imm, rs2, rs1, f3):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
        (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63


def _j(imm, rd):
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | \
        (((imm >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F


def bit(v, hi, lo=None):
    if lo is None:
        lo = hi
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)


def expand_rvc(c):
    """Return the 32-bit equivalent of compressed instruction c, or None if illegal."""
    op, f3 = c & 3, bit(c, 15, 13)
    rd = bit(c, 11, 7)
    rs2 = bit(c, 6, 2)
    rdp = 8 + bit(c, 4, 2)
    rs1p = 8 + bit(c, 9, 7)
    if op == 0:
        if f3 == 0:
            imm = (bit(c, 10, 7) << 6) | (bit(c, 12, 11) << 4) | (bit(c, 5) << 3) | (bit(c, 6) << 2)
            return _i(imm, 2, 0, rdp, 0x13) if imm else None
        imm = (bit(c, 5) << 6) | (bit(c, 12, 10) << 3) | (bit(c, 6) << 2)
        if f3 == 2:
            return _i(imm, rs1p, 2, rdp, 0x03)
        if f3 == 6:
            return _s(imm, rdp, rs1p, 2)
        return None
    if op == 1:
        imm6 = sext((bit(c, 12) << 5) | bit(c, 6, 2), 6)
        jimm = sext((bit(c, 12) << 11) | (bit(c, 8) << 10) | (bit(c, 10, 9) << 8) | (bit(c, 6) << 7) |
                    (bit(c, 7) << 6) | (bit(c, 2) << 5) | (bit(c, 11) << 4) | (bit(c, 5, 3) << 1), 12)
        if f3 == 0:
            return _i(imm6, rd, 0, rd, 0x13)
        if f3 == 1:
            return _j(jimm, 1)
        if f3 == 2:
            return _i(imm6, 0, 0, rd, 0x13)
        if f3 == 3:
            if rd == 2:
                imm = sext((bit(c, 12) << 9) | (bit(c, 4, 3) << 7) | (bit(c, 5) << 6) | (bit(c, 2) << 5) |
                           (bit(c, 6) << 4), 10)
                return _i(imm, 2, 0, 2, 0x13) if imm else None
            if imm6 == 0:
                return None
            return ((imm6 & 0xFFFFF) << 12) | (rd << 7) | 0x37
        if f3 == 4:
            f2 = bit(c, 11, 10)
            if f2 in (0, 1):
                if bit(c, 12):
                    return None
                return _i((0x20 << 5 if f2 else 0) | rs2, rs1p, 5, rs1p, 0x13)
            if f2 == 2:
                return _i(imm6, rs1p, 7, rs1p, 0x13)
            if bit(c, 12):
                return None
            sub = bit(c, 6, 5)
            return [_r(0x20, rdp, rs1p, 0, rs1p), _r(0, rdp, rs1p, 4, rs1p),
                    _r(0, rdp, rs1p, 6, rs1p), _r(0, rdp, rs1p, 7, rs1p)][sub]
        if f3 == 5:
            return _j(jimm, 0)
        bimm = sext((bit(c, 12) << 8) | (bit(c, 6, 5) << 6) | (bit(c, 2) << 5) | (bit(c, 11, 10) << 3) |
                    (bit(c, 4, 3) << 1), 9)
        return _b(bimm, 0, rs1p, 0 if f3 == 6 else 1)
    if op == 2:
        if f3 == 0:
            return None if bit(c, 12) else _i(rs2, rd, 1, rd, 0x13)
        if f3 == 2:
            if rd == 0:
                return None
            imm = (bit(c, 3, 2) << 6) | (bit(c, 12) << 5) | (bit(c, 6, 4) << 2)
            return _i(imm, 2, 2, rd, 0x03)
        if f3 == 4:
            if not bit(c, 12):
                if rs2 == 0:
                    return _i(0, rd, 0, 0, 0x67) if rd else None
                return _r(0, rs2, 0, 0, rd)
            if rd == 0 and rs2 == 0:
                return 0x00100073
            if rs2 == 0:
                return _i(0, rd, 0, 1, 0x67)
            return _r(0, rs2, rd, 0, rd)
        if f3 == 6:
            imm = (bit(c, 8, 7) << 6) | (bit(c, 12, 9) << 2)
            return _s(imm, rs2, 2, 2)
    return None


# --------------------------------------------------------------------------
class Memory:
    def __init__(self):
        self.pages = {}

    def _p(self, a):
        p = self.pages.get(a >> 12)
        if p is None:
            p = self.pages[a >> 12] = bytearray(4096)
        return p

    def read(self, a, n):
        v = 0
        for i in range(n):
            v |= self._p(a + i)[(a + i) & 0xFFF] << (8 * i)
        return v

    def write(self, a, v, n):
        for i in range(n):
            self._p(a + i)[(a + i) & 0xFFF] = (v >> (8 * i)) & 0xFF

    def load_elf(self, path):
        d = open(path, 'rb').read()
        assert d[:4] == b'\x7fELF' and d[4] == 1, "ELF32 expected"
        entry, phoff, shoff = struct.unpack_from('<III', d, 24)
        phentsize, phnum, shentsize, shnum = struct.unpack_from('<HHHH', d, 42)
        for i in range(phnum):
            p_type, off, vaddr, paddr, filesz, memsz = struct.unpack_from('<IIIIII', d, phoff + i * phentsize)
            if p_type == 1:
                for j in range(memsz):
                    self.write(paddr + j, d[off + j] if j < filesz else 0, 1)
        syms = {}
        for i in range(shnum):
            sh = struct.unpack_from('<IIIIIIIIII', d, shoff + i * shentsize)
            if sh[1] == 2:
                symoff, symsz, link, entsz = sh[4], sh[5], sh[6], sh[9]
                stroff = struct.unpack_from('<IIIIIIIIII', d, shoff + link * shentsize)[4]
                for s in range(symsz // entsz):
                    name_off, value = struct.unpack_from('<II', d, symoff + s * entsz)
                    e = d.index(b'\0', stroff + name_off)
                    syms[d[stroff + name_off:e].decode()] = value
        return entry, syms


# MMIO window: anything here is not modelled; load values come from the DUT.
def is_mmio(a):
    return 0x02000000 <= a < 0x02010000 or 0x10000000 <= a < 0x20000000


class Record:
    """One retirement record, in the same format the RTL testbench emits."""
    __slots__ = ('pc', 'insn', 'trap', 'pc_wdata', 'rd', 'rd_wdata', 'rmask', 'wmask', 'maddr')

    def __init__(self, pc, insn):
        self.pc, self.insn = pc, insn
        self.trap = 0
        self.pc_wdata = 0
        self.rd = 0
        self.rd_wdata = 0
        self.rmask = self.wmask = self.maddr = 0

    def __repr__(self):
        return (f"pc={self.pc:08x} insn={self.insn:08x} trap={self.trap} npc={self.pc_wdata:08x} "
                f"rd=x{self.rd}={self.rd_wdata:08x} rmask={self.rmask:x} wmask={self.wmask:x} maddr={self.maddr:08x}")


class ISS:
    SYNC_CSRS = {0xB00, 0xB80, 0xC00, 0xC80, 0x344} | set(range(0xB03, 0xB20)) | set(range(0xB83, 0xBA0)) \
        | set(range(0xC03, 0xC20)) | set(range(0xC83, 0xCA0))

    def __init__(self, mem, pc):
        self.mem = mem
        self.pc = pc
        self.x = [0] * 32
        self.csr = {0x300: 0x1800, 0x301: 0x40001104, 0x304: 0, 0x305: 0, 0x340: 0, 0x341: 0,
                    0x342: 0, 0x343: 0, 0x344: 0, 0x310: 0, 0x320: 0, 0xF11: 0, 0xF12: 0, 0xF13: 0, 0xF14: 0}
        self.minstret = 0
        self.dut_value = None   # value to use for non-deterministic reads (from DUT trace)

    # ---- CSRs ----
    def csr_exists(self, a):
        if a in self.csr or a in (0xB00, 0xB02, 0xB80, 0xB82, 0xC00, 0xC02, 0xC80, 0xC82):
            return True
        hi, lo = a >> 5, a & 0x1F
        return hi in (0x58, 0x5C, 0x60, 0x64, 0x19) and lo >= 3

    def csr_read(self, a):
        if a in (0xB02, 0xC02):
            return self.minstret & MASK
        if a in (0xB82, 0xC82):
            return (self.minstret >> 32) & MASK
        if a in self.SYNC_CSRS:
            return None     # non-deterministic -> take from DUT
        if (a >> 5) == 0x19:
            return 0
        return self.csr[a]

    def csr_write(self, a, v):
        v &= MASK
        if a == 0x300:
            self.csr[a] = 0x1800 | (v & 0x88)
        elif a == 0x304:
            self.csr[a] = v & 0x888
        elif a == 0x305:
            self.csr[a] = v & ~2 & MASK
        elif a == 0x341:
            self.csr[a] = v & ~1 & MASK
        elif a in (0x340, 0x342, 0x343):
            self.csr[a] = v
        elif a == 0xB02:
            self.minstret = (self.minstret & ~MASK) | v
            self.minstret_written = True
        elif a == 0xB82:
            self.minstret = (self.minstret & MASK) | (v << 32)
            self.minstret_written = True
        # misa, mstatush, mcountinhibit, mhpmevent*, counters: writes ignored / synced

    # ---- traps ----
    def trap_vector(self, irq, cause):
        tvec = self.csr[0x305]
        base = tvec & ~3
        return base + 4 * cause if (irq and tvec & 1) else base

    def enter_trap(self, irq, cause, tval, pc):
        st = self.csr[0x300]
        mie = (st >> 3) & 1
        self.csr[0x300] = (st & ~0x88) | (mie << 7)
        self.csr[0x341] = pc & ~1
        self.csr[0x342] = ((1 << 31) if irq else 0) | cause
        self.csr[0x343] = tval & MASK
        self.pc = self.trap_vector(irq, cause)

    def take_interrupt(self, cause):
        self.enter_trap(True, cause, 0, self.pc)

    # ---- memory ----
    def load(self, a, n):
        if is_mmio(a):
            return None
        return self.mem.read(a, n)

    def store(self, a, v, n):
        if not is_mmio(a):
            self.mem.write(a, v, n)

    # ---- execute one instruction ----
    def step(self, dut_rd_wdata=None):
        pc = self.pc
        lo = self.mem.read(pc, 2)
        is_c = (lo & 3) != 3
        raw = lo if is_c else self.mem.read(pc, 4)
        rec = Record(pc, raw)
        self.minstret_written = False
        try:
            if is_c:
                insn = expand_rvc(raw)
                if insn is None:
                    raise Trap(2, raw)
            else:
                insn = raw
            npc = self.execute(insn, pc, pc + (2 if is_c else 4), rec, raw, dut_rd_wdata)
            rec.pc_wdata = npc & MASK
            self.pc = npc & MASK
            if not self.minstret_written:
                self.minstret += 1
        except Trap as t:
            rec.trap = 1
            rec.rd = rec.rd_wdata = rec.rmask = rec.wmask = rec.maddr = 0
            self.enter_trap(False, t.cause, t.tval, pc)
            rec.pc_wdata = self.pc
        return rec

    def wr(self, rec, rd, v):
        if rd:
            self.x[rd] = u32(v)
            rec.rd, rec.rd_wdata = rd, u32(v)

    def execute(self, i, pc, seq, rec, raw, dut_val):
        x = self.x
        op = i & 0x7F
        rd, f3, rs1, rs2, f7 = bit(i, 11, 7), bit(i, 14, 12), bit(i, 19, 15), bit(i, 24, 20), bit(i, 31, 25)
        a, b = x[rs1], x[rs2]
        imm_i = sext(i >> 20, 12)
        ill = Trap(2, raw)

        if op == 0x37:
            self.wr(rec, rd, i & 0xFFFFF000)
        elif op == 0x17:
            self.wr(rec, rd, pc + (i & 0xFFFFF000))
        elif op == 0x6F:
            imm = sext((bit(i, 31) << 20) | (bit(i, 19, 12) << 12) | (bit(i, 20) << 11) | (bit(i, 30, 21) << 1), 21)
            self.wr(rec, rd, seq)
            return pc + imm
        elif op == 0x67:
            if f3:
                raise ill
            t = (a + imm_i) & ~1
            self.wr(rec, rd, seq)
            return t
        elif op == 0x63:
            imm = sext((bit(i, 31) << 12) | (bit(i, 7) << 11) | (bit(i, 30, 25) << 5) | (bit(i, 11, 8) << 1), 13)
            cond = {0: a == b, 1: a != b, 4: s32(a) < s32(b), 5: s32(a) >= s32(b), 6: a < b, 7: a >= b}
            if f3 not in cond:
                raise ill
            if cond[f3]:
                return pc + imm
        elif op == 0x03:
            if f3 not in (0, 1, 2, 4, 5):
                raise ill
            addr = u32(a + imm_i)
            n = 1 << (f3 & 3)
            if addr % n:
                raise Trap(4, addr)
            v = self.load(addr, n)
            if v is None:            # MMIO: value from DUT
                v = dut_val if dut_val is not None else 0
            elif not (f3 & 4):
                v = u32(sext(v, 8 * n))
            rec.maddr = addr & ~3
            rec.rmask = ((1 << n) - 1) << (addr & 3)
            self.wr(rec, rd, v)
        elif op == 0x23:
            if f3 not in (0, 1, 2):
                raise ill
            addr = u32(a + sext((f7 << 5) | rd, 12))
            n = 1 << f3
            if addr % n:
                raise Trap(6, addr)
            self.store(addr, b, n)
            rec.maddr = addr & ~3
            rec.wmask = ((1 << n) - 1) << (addr & 3)
        elif op == 0x13:
            sh = imm_i & 0x1F
            if f3 == 0:
                v = a + imm_i
            elif f3 == 2:
                v = int(s32(a) < imm_i)
            elif f3 == 3:
                v = int(a < u32(imm_i))
            elif f3 == 4:
                v = a ^ u32(imm_i)
            elif f3 == 6:
                v = a | u32(imm_i)
            elif f3 == 7:
                v = a & u32(imm_i)
            elif f3 == 1:
                if f7:
                    raise ill
                v = a << sh
            else:
                if f7 == 0:
                    v = a >> sh
                elif f7 == 0x20:
                    v = s32(a) >> sh
                else:
                    raise ill
            self.wr(rec, rd, v)
        elif op == 0x33:
            if f7 == 1:
                v = self.mext(f3, a, b)
            elif f7 == 0:
                v = [a + b, a << (b & 31), int(s32(a) < s32(b)), int(a < b), a ^ b, a >> (b & 31), a | b, a & b][f3]
            elif f7 == 0x20 and f3 == 0:
                v = a - b
            elif f7 == 0x20 and f3 == 5:
                v = s32(a) >> (b & 31)
            else:
                raise ill
            self.wr(rec, rd, v)
        elif op == 0x0F:
            if f3 not in (0, 1):
                raise ill
        elif op == 0x73:
            if f3 == 0:
                if i == 0x00000073:
                    raise Trap(11, 0)
                if i == 0x00100073:
                    raise Trap(3, pc)
                if i == 0x30200073:
                    st = self.csr[0x300]
                    mpie = (st >> 7) & 1
                    self.csr[0x300] = (st & ~0x88) | (mpie << 3) | 0x80
                    return self.csr[0x341]
                if i == 0x10500073:
                    return seq
                raise ill
            if f3 == 4:
                raise ill
            csr = i >> 20
            src = rs1 if f3 & 4 else a
            writes = (f3 & 3) == 1 or rs1 != 0
            if not self.csr_exists(csr) or (writes and (csr >> 10) == 3):
                raise ill
            old = self.csr_read(csr)
            if old is None:
                old = dut_val if dut_val is not None else 0
            if writes:
                new = [None, src, old | src, old & ~src][f3 & 3]
                self.csr_write(csr, new)
            self.wr(rec, rd, old)
        else:
            raise ill
        return seq

    @staticmethod
    def mext(f3, a, b):
        sa, sb = s32(a), s32(b)
        if f3 == 0:
            return a * b
        if f3 == 1:
            return (sa * sb) >> 32
        if f3 == 2:
            return (sa * b) >> 32
        if f3 == 3:
            return (a * b) >> 32
        if b == 0:
            return [MASK, MASK, a, a][f3 - 4]
        if f3 == 4:
            if sa == -2**31 and sb == -1:
                return a
            q = abs(sa) // abs(sb)
            return -q if (sa < 0) != (sb < 0) else q
        if f3 == 5:
            return a // b
        if f3 == 6:
            if sa == -2**31 and sb == -1:
                return 0
            r = abs(sa) % abs(sb)
            return -r if sa < 0 else r
        return a % b
