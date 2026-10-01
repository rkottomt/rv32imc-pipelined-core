// tb_soc.cpp - Verilator testbench for the full SoC (core + caches + bus + RAM).
//
// Converts the ELF into a RAM image ($readmemh), runs until the program
// writes the simulation controller, and reports performance statistics.
//
// Plusargs: +elf=<file> +trace=<file> +max_cycles=<n> +seed=<n> +irq_rand=<pct>
//           +fst=<file> +stats=<file>  (key=value performance summary)
#include <verilated.h>
#include "Vrv_soc.h"
#if VM_TRACE
#include <verilated_fst_c.h>
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <fstream>
#include <random>
#include <string>
#include <vector>

static long plusarg_int(const char* name, long dflt) {
    std::string m = Verilated::commandArgsPlusMatch(name);
    if (m.empty()) return dflt;
    return strtol(m.c_str() + strlen(name) + 2, nullptr, 0);
}
static std::string plusarg_str(const char* name) {
    std::string m = Verilated::commandArgsPlusMatch(name);
    if (m.empty()) return "";
    return m.substr(strlen(name) + 2);
}

// Load PT_LOAD segments that fall inside [0, ram_bytes) into a word image.
static bool elf_to_image(const std::string& fn, std::vector<uint32_t>& img) {
    std::ifstream f(fn, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot open %s\n", fn.c_str()); return false; }
    std::vector<uint8_t> d((std::istreambuf_iterator<char>(f)), {});
    auto u16 = [&](size_t o) { return (uint32_t)(d[o] | (d[o + 1] << 8)); };
    auto u32 = [&](size_t o) { return (uint32_t)(d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | ((uint32_t)d[o + 3] << 24)); };
    if (d.size() < 52 || memcmp(d.data(), "\x7f" "ELF", 4)) return false;
    uint32_t phoff = u32(28), phnum = u16(44), phentsize = u16(42);
    for (uint32_t i = 0; i < phnum; i++) {
        size_t ph = phoff + i * phentsize;
        if (u32(ph) != 1) continue;
        uint32_t off = u32(ph + 4), paddr = u32(ph + 12), filesz = u32(ph + 16), memsz = u32(ph + 20);
        for (uint32_t j = 0; j < memsz; j++) {
            uint32_t a = paddr + j;
            if (a / 4 >= img.size()) continue;   // e.g. .tohost in MMIO space
            uint8_t b = j < filesz ? d[off + j] : 0;
            img[a / 4] = (img[a / 4] & ~(0xffu << (8 * (a & 3)))) | ((uint32_t)b << (8 * (a & 3)));
        }
    }
    return true;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string elf = plusarg_str("elf");
    if (elf.empty()) { fprintf(stderr, "usage: +elf=<file>\n"); return 2; }
    long ram_words = plusarg_int("ram_words", 1 << 14);
    std::vector<uint32_t> img(ram_words, 0);
    if (!elf_to_image(elf, img)) return 2;
    std::string hex = elf + ".hex";
    {
        FILE* h = fopen(hex.c_str(), "w");
        for (auto w : img) fprintf(h, "%08x\n", w);
        fclose(h);
    }
    std::string harg = "+ram_hex=" + hex;
    const char* extra[] = {harg.c_str()};
    Verilated::commandArgsAdd(1, extra);

    std::string trace_fn = plusarg_str("trace");
    long max_cycles = plusarg_int("max_cycles", 20000000);
    int irq_pct = plusarg_int("irq_rand", 0);
    std::mt19937 rng(plusarg_int("seed", 1));
    FILE* trace = trace_fn.empty() ? nullptr : fopen(trace_fn.c_str(), "w");

    Vrv_soc* top = new Vrv_soc;
#if VM_TRACE
    VerilatedFstC* tfp = nullptr;
    std::string fst = plusarg_str("fst");
    if (!fst.empty()) { Verilated::traceEverOn(true); tfp = new VerilatedFstC; top->trace(tfp, 99); tfp->open(fst.c_str()); }
#endif
    uint64_t t = 0;
    auto tick = [&]() {
        top->clk = 1; top->eval();
#if VM_TRACE
        if (tfp) tfp->dump(t);
#endif
        t += 5;
        top->clk = 0; top->eval();
#if VM_TRACE
        if (tfp) tfp->dump(t);
#endif
        t += 5;
    };

    top->rst = 1; top->clk = 0; top->irq_external = 0;
    for (int i = 0; i < 5; i++) tick();
    top->rst = 0;

    uint64_t cycle = 0, instret = 0, ic_miss = 0, dc_miss = 0, dc_wb = 0;
    int hold = 0;
    for (cycle = 0; cycle < (uint64_t)max_cycles && !top->sim_exit; cycle++) {
        if (hold > 0) hold--;
        else if (irq_pct > 0 && (int)(rng() % 100) < irq_pct) hold = 1 + rng() % 8;
        top->irq_external = hold > 0;
        tick();
        ic_miss += top->stat_icache_miss;
        dc_miss += top->stat_dcache_miss;
        dc_wb   += top->stat_dcache_wb;
        if (top->rvfi_valid) {
            instret++;
            if (trace)
                fprintf(trace, "%08x %08x %d %d %d %d %08x %d %08x %x %x %08x\n",
                        top->rvfi_pc_rdata, top->rvfi_insn, top->rvfi_trap, top->rvfi_intr,
                        top->dbg_irq, top->dbg_irq_cause, top->rvfi_pc_wdata, top->rvfi_rd_addr,
                        top->rvfi_rd_wdata, top->rvfi_mem_rmask, top->rvfi_mem_wmask, top->rvfi_mem_addr);
        }
    }
    if (trace) fclose(trace);
#if VM_TRACE
    if (tfp) tfp->close();
#endif
    int rc;
    if (!top->sim_exit) { printf("TIMEOUT after %llu cycles\n", (unsigned long long)cycle); rc = 255; }
    else if (top->sim_exit_code == 1) { printf("PASS  "); rc = 0; }
    else { printf("FAIL  code=%u ", top->sim_exit_code >> 1); rc = 1; }
    printf("cycles=%llu instret=%llu IPC=%.3f icache_miss=%llu dcache_miss=%llu dcache_wb=%llu\n",
           (unsigned long long)cycle, (unsigned long long)instret, cycle ? (double)instret / cycle : 0.0,
           (unsigned long long)ic_miss, (unsigned long long)dc_miss, (unsigned long long)dc_wb);
    std::string stats = plusarg_str("stats");
    if (!stats.empty()) {
        FILE* s = fopen(stats.c_str(), "w");
        fprintf(s, "cycles=%llu\ninstret=%llu\nicache_miss=%llu\ndcache_miss=%llu\ndcache_wb=%llu\n",
                (unsigned long long)cycle, (unsigned long long)instret, (unsigned long long)ic_miss,
                (unsigned long long)dc_miss, (unsigned long long)dc_wb);
        fclose(s);
    }
    delete top;
    return rc;
}
