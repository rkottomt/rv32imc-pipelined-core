"""Unit-level cocotb testbenches.

Run everything:   python3 -m pytest verif/cocotb/test_units.py -v
Each pytest test builds one RTL block with Icarus Verilog and runs its cocotb
test(s). The cocotb tests live in the same file (selected via
`test_module=__name__`).
"""
import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Timer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'verif', 'iss'))
from rv32iss import expand_rvc, ISS  # noqa: E402

MASK = 0xFFFFFFFF


# =========================================================================
# RVC expander: exhaustive equivalence against the ISS's independent expander
@cocotb.test()
async def rvc_exhaustive(dut):
    """All 65536 16-bit patterns: legality and expansion must match the ISS."""
    mismatches = 0
    checked = 0
    for c in range(1 << 16):
        if c & 3 == 3:
            continue                     # not a compressed encoding
        dut.c.value = c
        await Timer(1, unit='ns')
        exp = expand_rvc(c)
        ill = int(dut.illegal.value)
        checked += 1
        if exp is None:
            if not ill:
                mismatches += 1
                dut._log.error(f"{c:04x}: RTL legal ({int(dut.x.value):08x}) but ISS says illegal")
        else:
            if ill or int(dut.x.value) != exp:
                mismatches += 1
                dut._log.error(f"{c:04x}: RTL {int(dut.x.value):08x} ill={ill}  ISS {exp:08x}")
        if mismatches > 10:
            break
    dut._log.info(f"checked {checked} compressed encodings, {mismatches} mismatches")
    assert mismatches == 0


# =========================================================================
# MUL/DIV unit
MD_CORNERS = [0, 1, 2, 3, MASK, MASK - 1, 0x80000000, 0x7FFFFFFF, 0x80000001, 0x55555555, 0xAAAAAAAA,
              0x0000FFFF, 0xFFFF0000, 7, 0xFFFFFFF9]


@cocotb.test()
async def muldiv_random(dut):
    """Corner-case cross product + random operands for all 8 M-extension ops."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    dut.rst.value = 1
    dut.valid.value = 0
    dut.kill.value = 0
    dut.hold.value = 0
    dut.consume.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    rng = random.Random(42)
    vectors = [(a, b) for a in MD_CORNERS for b in MD_CORNERS]
    vectors += [(rng.getrandbits(32), rng.getrandbits(32)) for _ in range(400)]
    vectors += [(rng.getrandbits(32), rng.getrandbits(rng.randint(1, 8))) for _ in range(200)]
    n = 0
    for a, b in vectors:
        for op in range(8):
            dut.op.value = op
            dut.a.value = a
            dut.b.value = b
            dut.valid.value = 1
            cycles = 0
            # wait until not busy (combinational), sampled before the edge
            while True:
                await ReadOnly()
                if not int(dut.busy.value):
                    break
                await RisingEdge(dut.clk)
                cycles += 1
                assert cycles < 40, "divider hung"
            got = int(dut.result.value)
            exp = ISS.mext(op, a, b) & MASK
            assert got == exp, f"op={op} a={a:08x} b={b:08x}: got {got:08x} exp {exp:08x}"
            await RisingEdge(dut.clk)
            dut.consume.value = 1
            await RisingEdge(dut.clk)
            dut.consume.value = 0
            dut.valid.value = 0
            await RisingEdge(dut.clk)
            n += 1
    dut._log.info(f"{n} M-extension operations checked")


# =========================================================================
# D-cache: random traffic against a reference memory, random memory latency
class MemModel:
    """Slave model for the cache's memory port with random latency/ready."""

    def __init__(self, dut, rng, words):
        self.dut, self.rng, self.mem = dut, rng, words
        self.reads = self.writes = 0

    async def run(self):
        d = self.dut
        d.m_req_ready.value = 0
        d.m_resp_valid.value = 0
        while True:
            await RisingEdge(d.clk)
            d.m_resp_valid.value = 0
            d.m_req_ready.value = int(self.rng.random() < 0.7)
            await ReadOnly()
            if int(d.m_req_valid.value) and int(d.m_req_ready.value):
                a = int(d.m_req_addr.value)
                we = int(d.m_req_we.value)
                be = int(d.m_req_be.value)
                wd = int(d.m_req_wdata.value) if we else 0
                rdata = self.mem.get(a >> 2, 0)
                if we:
                    self.writes += 1
                    old = self.mem.get(a >> 2, 0)
                    for i in range(4):
                        if be >> i & 1:
                            old = (old & ~(0xFF << 8 * i)) | (wd & (0xFF << 8 * i))
                    self.mem[a >> 2] = old
                else:
                    self.reads += 1
                lat = self.rng.choice([0, 0, 1, 3, 6])
                await RisingEdge(d.clk)
                d.m_req_ready.value = 0
                for _ in range(lat):
                    await RisingEdge(d.clk)
                d.m_resp_valid.value = 1
                d.m_resp_rdata.value = rdata


@cocotb.test()
async def dcache_random(dut):
    """5000 random loads/stores/flushes; every load checked against a shadow
    memory; after a final flush, backing memory must equal the shadow."""
    rng = random.Random(7)
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    backing = {}
    shadow = {}
    mm = MemModel(dut, rng, backing)
    dut.rst.value = 1
    dut.req_valid.value = 0
    dut.req_flush.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    cocotb.start_soon(mm.run())

    # address pool: a few cacheable lines that conflict in a tiny cache, plus MMIO
    lines = [rng.randrange(0, 1 << 16) & ~0xF for _ in range(24)]
    mmio = 0x10001000

    async def access(addr, we, be, wdata, flush=0):
        dut.req_valid.value = 1
        dut.req_addr.value = addr
        dut.req_we.value = we
        dut.req_be.value = be
        dut.req_wdata.value = wdata
        dut.req_flush.value = flush
        while True:
            await ReadOnly()
            if int(dut.req_ready.value):
                break
            await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        dut.req_valid.value = 0
        dut.req_flush.value = 0
        while True:
            await ReadOnly()
            if int(dut.resp_valid.value):
                v = dut.resp_rdata.value
                r = int(v) if v.is_resolvable else None   # store acks carry no data
                await RisingEdge(dut.clk)
                return r
            await RisingEdge(dut.clk)

    n_ld = n_st = n_fl = 0
    for i in range(5000):
        k = rng.random()
        if k < 0.01:
            await access(0, 0, 0xF, 0, flush=1)
            n_fl += 1
            continue
        addr = (rng.choice(lines) + 4 * rng.randrange(4)) if rng.random() < 0.95 else mmio
        if k < 0.5:
            r = await access(addr, 0, 0xF, 0)
            exp = shadow.get(addr >> 2, backing.get(addr >> 2, 0)) if addr != mmio else backing.get(addr >> 2, 0)
            assert r == exp, f"#{i} load {addr:08x}: got {r:08x} exp {exp:08x}"
            n_ld += 1
        else:
            be = rng.choice([1, 2, 4, 8, 3, 12, 15])
            wd = rng.getrandbits(32)
            await access(addr, 1, be, wd)
            old = shadow.get(addr >> 2, backing.get(addr >> 2, 0))
            for b in range(4):
                if be >> b & 1:
                    old = (old & ~(0xFF << 8 * b)) | (wd & (0xFF << 8 * b))
            if addr == mmio:
                # uncached: goes straight to memory
                pass
            else:
                shadow[addr >> 2] = old
            n_st += 1
    await access(0, 0, 0xF, 0, flush=1)
    for w, v in shadow.items():
        assert backing.get(w, 0) == v, f"after flush memory[{w*4:08x}]={backing.get(w,0):08x} exp {v:08x}"
    dut._log.info(f"loads={n_ld} stores={n_st} flushes={n_fl}; memory reads={mm.reads} writes={mm.writes}")


# =========================================================================
# pytest entry points (build + run each block)
def _run(top, sources, testcase, parameters=None):
    from cocotb_tools.runner import get_runner
    runner = get_runner('icarus')
    build = os.path.join(ROOT, 'build', 'cocotb', top)
    runner.build(sources=[os.path.join(ROOT, s) for s in sources], hdl_toplevel=top,
                 includes=[os.path.join(ROOT, 'rtl', 'core')], build_dir=build,
                 parameters=parameters or {}, timescale=('1ns', '1ps'), always=True)
    runner.test(hdl_toplevel=top, test_module='test_units', testcase=testcase, build_dir=build,
                test_dir=HERE)


def test_rvc_expander():
    _run('rv_rvc_expand', ['rtl/core/rv_rvc_expand.v'], 'rvc_exhaustive')


def test_muldiv():
    _run('rv_muldiv', ['rtl/core/rv_muldiv.v'], 'muldiv_random')


def test_dcache():
    # 4-set cache so the random traffic causes constant evictions/write-backs
    _run('rv_dcache', ['rtl/cache/rv_dcache.v', 'rtl/cache/rv_sram.v'], 'dcache_random',
         {'SET_BITS': 2})
