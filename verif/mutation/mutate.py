#!/usr/bin/env python3
"""mutate.py - mutation testing: does the verification suite catch real bugs?

Each mutant injects one realistic design bug (the kind that happens in real
pipelines) into a copy of the RTL, rebuilds the simulators from that copy, and
runs a quick detection suite:
    core:  riscv-tests + 8 constrained-random seeds (ISS co-sim, bus stress, IRQs)
    SoC:   riscv-tests on the cached SoC, random co-sim on a tiny-cache SoC, directed tests
A mutant is "killed" if any check fails. A surviving mutant means a hole in
the verification, which is what this exercise is for.

    python3 verif/mutation/mutate.py            # all mutants
    python3 verif/mutation/mutate.py 3 7        # selected mutants
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
WORK = os.path.join(ROOT, 'build', 'mutation')

# (file, original text, mutated text, description)
MUTANTS = [
    ('rtl/core/rv_core.v', 'else if (mem_valid && mem_rd_we && mem_rd == r) fwd = mem_result;',
     'else if (1\'b0) fwd = mem_result;', 'EX/MEM -> EX forwarding path removed'),
    ('rtl/core/rv_core.v', 'else if (wb_rf_we && wb_rf_wa == r)          fwd = wb_rf_wd;',
     'else if (1\'b0)          fwd = wb_rf_wd;', 'MEM/WB -> EX forwarding path removed'),
    ('rtl/core/rv_core.v', 'wire ex_late = ex_load || ex_csr;',
     'wire ex_late = ex_load;', 'CSR-use hazard not detected (only load-use)'),
    ('rtl/core/rv_regfile.v', "assign rd1 = (ra1 == 5'd0) ? 32'd0 : (we && wa == ra1) ? wd : mem[ra1];",
     "assign rd1 = (ra1 == 5'd0) ? 32'd0 : mem[ra1];", 'register-file write-through bypass missing (rs1)'),
    ('rtl/core/rv_core.v', '            ex_rs1_val <= ex_a_reg;\n            ex_rs2_val <= ex_b_reg;',
     '', 'operands not re-captured while EX is stalled'),
    ('rtl/core/rv_muldiv.v', '!running && !done && !kill && !hold;',
     '!running && !done && !kill;', 'divider samples operands during a stall (real bug #2)'),
    ('rtl/core/rv_core.v', "3'b110:  br_taken = br_ltu;", "3'b110:  br_taken = br_lt;",
     'BLTU uses a signed comparison'),
    ('rtl/core/rv_rvc_expand.v', "x = enc_i({7'b0100000, c[6:2]}, rs1p, 3'b101, rs1p, `OP_OPIMM);",
     "x = enc_i({7'b0000000, c[6:2]}, rs1p, 3'b101, rs1p, `OP_OPIMM);", 'C.SRAI expanded as SRLI'),
    ('rtl/core/rv_csr.v', 'mstatus_mie  <= mstatus_mpie;', 'mstatus_mie  <= 1\'b1;',
     'MRET always re-enables interrupts'),
    ('rtl/core/rv_frontend.v', 'drop <= inflight_nxt;\n                fpc  <= redirect_pc;',
     'drop <= 3\'d0;\n                fpc  <= redirect_pc;', 'stale fetch responses not dropped after a redirect'),
    ('rtl/core/rv_frontend.v', "straddle ? {fq_data[n][15:0], lo16} : fq_data[h];",
     "straddle ? {fq_data[h][15:0], lo16} : fq_data[h];", 'straddling instruction takes upper half from wrong word'),
    ('rtl/core/rv_core.v', "assign retire   = mem_fire && !mem_trap;", "assign retire   = wb_fire && !wb_trap;",
     'minstret counted at WB instead of MEM (real bug #1)'),
    ('rtl/cache/rv_dcache.v', 'wire byp_hit = byp_valid && byp_addr == s1_addr[2 +: SET_BITS + 2];',
     "wire byp_hit = 1'b0;", 'D-cache store->load bypass missing'),
    ('rtl/cache/rv_dcache.v', 'state  <= victim_dirty ? S_WB_RD : S_RF_REQ;', 'state  <= S_RF_REQ;',
     'D-cache drops dirty lines on eviction (no write-back)'),
    ('rtl/cache/rv_icache.v', "                v0 <= 0; v1 <= 0;\n                if (state != S_IDLE)",
     "                if (state != S_IDLE)", 'FENCE.I does not invalidate the I-cache'),
    ('rtl/core/rv_core.v', 'wire mem_mem_op = mem_valid && (mem_load || mem_store || mem_fencei) && !mem_trap;',
     'wire mem_mem_op = mem_valid && (mem_load || mem_store) && !mem_trap;',
     'FENCE.I does not flush the D-cache'),
]


def sh(cmd, cwd=None, timeout=1800):
    try:
        r = subprocess.run(cmd, shell=True, cwd=cwd or ROOT, text=True, capture_output=True, timeout=timeout)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return 124, 'timeout'


def run_mutant(i, f, old, new):
    d = os.path.join(WORK, f'm{i}')
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(os.path.join(ROOT, 'rtl'), os.path.join(d, 'rtl'))
    p = os.path.join(d, f)
    src = open(p).read()
    assert src.count(old) == 1, f'mutant {i}: pattern not found exactly once in {f}'
    open(p, 'w').write(src.replace(old, new))
    core = sorted(os.path.join(d, 'rtl/core', x) for x in os.listdir(os.path.join(d, 'rtl/core')) if x.endswith('.v'))
    soc = core + sorted(os.path.join(d, 'rtl', sub, x) for sub in ('cache', 'soc')
                        for x in os.listdir(os.path.join(d, 'rtl', sub)) if x.endswith('.v'))
    vfl = f'-Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -O2 -I{d}/rtl/core'
    # (each mutant builds into its own directory, so they can run in parallel)
    rc, out = sh(f'verilator --cc --exe --build -j 8 {vfl} --top-module rv_core -Mdir {d}/core '
                 f'{" ".join(core)} sim/tb_core.cpp -o Vrv_core')
    if rc:
        return 'killed (build)', ''
    rc, out = sh(f'verilator --cc --exe --build -j 8 {vfl} --top-module rv_soc -Mdir {d}/soc '
                 f'{" ".join(soc)} sim/tb_soc.cpp -o Vrv_soc')
    if rc:
        return 'killed (build)', ''
    # 1. riscv-tests on the core
    rc, out = sh(f'make run-tests SIM_CORE={d}/core/Vrv_core SIMARGS=+max_cycles=200000')
    if rc:
        return 'killed', 'riscv-tests (core)'
    # 2. constrained random + ISS co-sim
    rc, out = sh(f'SIM={d}/core/Vrv_core OUT={d}/random verif/rig/run_random.sh 7000 8 2000')
    if rc:
        return 'killed', 'random co-sim'
    # 3. riscv-tests on the SoC (caches)
    rc, out = sh(f'make run-tests-soc SIM_SOC={d}/soc/Vrv_soc SIMARGS=+max_cycles=400000')
    if rc:
        return 'killed', 'riscv-tests (SoC)'
    # 4. constrained-random co-sim on a *stressed* SoC: 2-way x 4-set caches and
    #    6-cycle memory, so lines are constantly evicted and written back.
    #    (Added after mutant M14 - "dirty lines dropped on eviction" - survived:
    #    the other SoC tests all fit in the 4 KiB cache and never evict.)
    rc, out = sh(f'verilator --cc --exe --build -j 8 {vfl} -GRAM_LATENCY=6 -GCACHE_SET_BITS=2 '
                 f'--top-module rv_soc -Mdir {d}/soc_stress {" ".join(soc)} sim/tb_soc.cpp -o Vrv_soc')
    if rc:
        return 'killed (build)', ''
    rc, out = sh(f'MODE=soc SIM={d}/soc_stress/Vrv_soc OUT={d}/random_soc verif/rig/run_random.sh 7100 4 2000')
    if rc:
        return 'killed', 'random co-sim (stress SoC)'
    # 5. directed tests on core (co-sim) + SoC
    for t in ('bp_fixup', 'irq_test'):
        e = f'{ROOT}/build/sw/{t}.elf'
        rc1, _ = sh(f'{d}/core/Vrv_core +elf={e} +trace={d}/{t}.trace')
        rc2, _ = sh(f'python3 verif/iss/compare.py {e} {d}/{t}.trace --quiet')
        rc3, _ = sh(f'{d}/soc/Vrv_soc +elf={e}')
        if rc1 or rc2 or rc3:
            return 'killed', f'directed {t}'
    return 'SURVIVED', ''


def main():
    sel = [int(a) for a in sys.argv[1:]] or range(1, len(MUTANTS) + 1)
    os.makedirs(WORK, exist_ok=True)
    sh('make tests tests-soc && make -C sw tests')
    from concurrent.futures import ThreadPoolExecutor

    def job(i):
        f, old, new, desc = MUTANTS[i - 1]
        status, by = run_mutant(i, f, old, new)
        print(f'M{i:02d} {status:14s} {by:22s} {desc}', flush=True)
        return (i, desc, status, by)

    with ThreadPoolExecutor(max_workers=int(os.environ.get('JOBS', '4'))) as ex:
        results = sorted(ex.map(job, sel))
    killed = sum(1 for r in results if r[2].startswith('killed'))
    print(f'\nmutation score: {killed}/{len(results)} killed')
    with open(os.path.join(WORK, 'report.md'), 'w') as fh:
        fh.write('| # | Injected bug | Result | First caught by |\n|---|---|---|---|\n')
        for i, desc, status, by in results:
            fh.write(f'| M{i:02d} | {desc} | {status} | {by} |\n')
        fh.write(f'\n**Mutation score: {killed}/{len(results)}**\n')


if __name__ == '__main__':
    main()
