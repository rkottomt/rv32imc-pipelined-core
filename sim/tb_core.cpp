// tb_core.cpp - Verilator testbench for rv_core.
//
// Models the instruction and data buses (configurable latency + random
// back-pressure), a CLINT-style timer, a console UART and the riscv-tests
// `tohost` convention. Emits a retirement trace (from RVFI) that the Python
// golden model (verif/iss) compares against.
//
// Plusargs:
//   +elf=<file>        program to load (required)
//   +trace=<file>      write retirement trace
//   +max_cycles=<n>    timeout (default 2,000,000)
//   +ilat=<n> +dlat=<n> bus response latency in cycles (default 1)
//   +stall=<pct>       % of cycles a bus refuses requests (default 0)
//   +seed=<n>          RNG seed for random stalls/interrupts
//   +irq_rand=<pct>    randomly pulse the external interrupt line
//   +fst=<file>        dump waveform (FST)
#include <verilated.h>
#include "Vrv_core.h"
#if VM_COVERAGE
#include <verilated_cov.h>
#endif
#if VM_TRACE
#include <verilated_fst_c.h>
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>
#include <random>
#include <fstream>

// ---------------------------------------------------------------- memory
struct Memory {
    std::unordered_map<uint32_t, std::vector<uint8_t>> pages;
    uint8_t* page(uint32_t a) {
        auto& p = pages[a >> 12];
        if (p.empty()) p.resize(4096, 0);
        return p.data();
    }
    uint32_t read32(uint32_t a) {
        a &= ~3u;
        uint8_t* p = page(a) + (a & 0xfff);
        return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
    }
    void write(uint32_t a, uint32_t d, unsigned be) {
        a &= ~3u;
        uint8_t* p = page(a) + (a & 0xfff);
        for (int i = 0; i < 4; i++)
            if (be & (1u << i)) p[i] = (d >> (8 * i)) & 0xff;
    }
    void write8(uint32_t a, uint8_t v) { page(a)[a & 0xfff] = v; }
};

// ---------------------------------------------------------------- ELF
struct ElfInfo { uint32_t entry = 0, tohost = 0; bool has_tohost = false; };

static bool load_elf(const char* fn, Memory& mem, ElfInfo& info) {
    std::ifstream f(fn, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot open %s\n", fn); return false; }
    std::vector<uint8_t> d((std::istreambuf_iterator<char>(f)), {});
    auto u16 = [&](size_t o) { return (uint32_t)(d[o] | (d[o + 1] << 8)); };
    auto u32 = [&](size_t o) { return (uint32_t)(d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | ((uint32_t)d[o + 3] << 24)); };
    if (d.size() < 52 || memcmp(d.data(), "\x7f" "ELF", 4) || d[4] != 1) { fprintf(stderr, "not an ELF32 file\n"); return false; }
    info.entry = u32(24);
    uint32_t phoff = u32(28), shoff = u32(32);
    uint32_t phnum = u16(44), shnum = u16(48), shentsize = u16(46), phentsize = u16(42);
    for (uint32_t i = 0; i < phnum; i++) {
        size_t ph = phoff + i * phentsize;
        if (u32(ph) != 1) continue;  // PT_LOAD
        uint32_t off = u32(ph + 4), paddr = u32(ph + 12), filesz = u32(ph + 16), memsz = u32(ph + 20);
        for (uint32_t j = 0; j < memsz; j++) mem.write8(paddr + j, j < filesz ? d[off + j] : 0);
    }
    // symbol table -> tohost
    for (uint32_t i = 0; i < shnum; i++) {
        size_t sh = shoff + i * shentsize;
        if (u32(sh + 4) != 2) continue;  // SHT_SYMTAB
        uint32_t symoff = u32(sh + 16), symsz = u32(sh + 20), link = u32(sh + 24), entsz = u32(sh + 36);
        size_t strsh = shoff + link * shentsize;
        uint32_t stroff = u32(strsh + 16);
        for (uint32_t s = 0; s < symsz / entsz; s++) {
            size_t sym = symoff + s * entsz;
            const char* name = (const char*)&d[stroff + u32(sym)];
            if (!strcmp(name, "tohost")) { info.tohost = u32(sym + 4); info.has_tohost = true; }
        }
    }
    return true;
}

// ---------------------------------------------------------------- bus model
struct Resp { uint64_t due; uint32_t data; };

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

// Memory map seen by the core-level testbench
static const uint32_t UART_TX     = 0x10000000;
static const uint32_t CLINT_BASE  = 0x02000000;
static const uint32_t CLINT_MSIP  = CLINT_BASE + 0x0;
static const uint32_t CLINT_CMP   = CLINT_BASE + 0x4000;
static const uint32_t CLINT_TIME  = CLINT_BASE + 0xBFF8;
static const uint32_t SIM_CTRL    = 0x10002000;  // write: exit code

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string elf = plusarg_str("elf");
    if (elf.empty()) { fprintf(stderr, "usage: +elf=<file>\n"); return 2; }
    std::string trace_fn = plusarg_str("trace");
    long max_cycles = plusarg_int("max_cycles", 2000000);
    int ilat = plusarg_int("ilat", 1), dlat = plusarg_int("dlat", 1);
    int stall_pct = plusarg_int("stall", 0);
    int irq_pct = plusarg_int("irq_rand", 0);
    std::mt19937 rng(plusarg_int("seed", 1));
    auto chance = [&](int pct) { return pct > 0 && (int)(rng() % 100) < pct; };

    Memory mem;
    ElfInfo info;
    if (!load_elf(elf.c_str(), mem, info)) return 2;

    FILE* trace = trace_fn.empty() ? nullptr : fopen(trace_fn.c_str(), "w");

    Vrv_core* top = new Vrv_core;
#if VM_TRACE
    VerilatedFstC* tfp = nullptr;
    std::string fst = plusarg_str("fst");
    if (!fst.empty()) { Verilated::traceEverOn(true); tfp = new VerilatedFstC; top->trace(tfp, 99); tfp->open(fst.c_str()); }
#endif
    uint64_t sim_time = 0;
    auto tick = [&]() {
        top->clk = 1; top->eval();
#if VM_TRACE
        if (tfp) tfp->dump(sim_time);
#endif
        sim_time += 5;
        top->clk = 0; top->eval();
#if VM_TRACE
        if (tfp) tfp->dump(sim_time);
#endif
        sim_time += 5;
    };

    // reset
    top->clk = 0; top->rst = 1;
    top->boot_addr = info.entry;
    top->ibus_req_ready = 0; top->ibus_resp_valid = 0;
    top->dbus_req_ready = 0; top->dbus_resp_valid = 0;
    top->irq_software = 0; top->irq_timer = 0; top->irq_external = 0;
    for (int i = 0; i < 5; i++) tick();
    top->rst = 0;

    std::deque<Resp> iq, dq;
    uint64_t mtime = 0, mtimecmp = ~0ull;
    uint32_t msip = 0;
    int ext_irq_hold = 0;
    int exit_code = -1;
    uint64_t cycle = 0, retired = 0;
    std::string uart_line;

    for (cycle = 0; cycle < (uint64_t)max_cycles && exit_code < 0; cycle++) {
        // ---- drive inputs for this cycle
        top->ibus_req_ready = !chance(stall_pct);
        top->dbus_req_ready = !chance(stall_pct) && dq.empty();
        top->ibus_resp_valid = !iq.empty() && iq.front().due <= cycle;
        top->ibus_resp_data  = top->ibus_resp_valid ? iq.front().data : 0;
        top->dbus_resp_valid = !dq.empty() && dq.front().due <= cycle;
        top->dbus_resp_rdata = top->dbus_resp_valid ? dq.front().data : 0;
        top->irq_timer    = mtime >= mtimecmp;
        top->irq_software = msip & 1;
        if (ext_irq_hold > 0) ext_irq_hold--;
        else if (chance(irq_pct)) ext_irq_hold = 1 + rng() % 8;
        top->irq_external = ext_irq_hold > 0;
        top->eval();

        // ---- sample handshakes (before the clock edge)
        bool ireq = top->ibus_req_valid && top->ibus_req_ready;
        uint32_t iaddr = top->ibus_req_addr;
        bool dreq = top->dbus_req_valid && top->dbus_req_ready;
        bool dflush = top->dbus_req_flush;
        uint32_t daddr = top->dbus_req_addr, dwdata = top->dbus_req_wdata;
        bool dwe = top->dbus_req_we;
        unsigned dbe = top->dbus_req_be;
        if (top->ibus_resp_valid) iq.pop_front();
        if (top->dbus_resp_valid) dq.pop_front();

        tick();

        // ---- retirement trace
        if (top->rvfi_valid) {
            retired++;
            if (trace) {
                fprintf(trace, "%08x %08x %d %d %d %d %08x %d %08x %x %x %08x\n",
                        top->rvfi_pc_rdata, top->rvfi_insn, top->rvfi_trap, top->rvfi_intr,
                        top->dbg_irq, top->dbg_irq_cause, top->rvfi_pc_wdata,
                        top->rvfi_rd_addr, top->rvfi_rd_wdata, top->rvfi_mem_rmask,
                        top->rvfi_mem_wmask, top->rvfi_mem_addr);
            }
        }

        // ---- service accepted requests
        if (ireq) iq.push_back({cycle + ilat, mem.read32(iaddr)});
        if (dreq) {
            uint32_t rdata = 0;
            uint32_t a = daddr;
            if (dflush) {
                // FENCE.I write-back request: nothing cached here, just ack
            } else if (a == UART_TX && dwe) {
                char c = dwdata & 0xff;
                putchar(c); fflush(stdout);
            } else if (a == SIM_CTRL && dwe) {
                // "tohost" convention: 1 = pass, otherwise (code << 1) | 1
                if (dwdata) exit_code = (dwdata == 1) ? 0 : (int)(dwdata >> 1);
            } else if (a >= CLINT_BASE && a < CLINT_BASE + 0x10000) {
                if (dwe) {
                    if (a == CLINT_MSIP) msip = dwdata;
                    else if (a == CLINT_CMP)     mtimecmp = (mtimecmp & 0xffffffff00000000ull) | dwdata;
                    else if (a == CLINT_CMP + 4) mtimecmp = (mtimecmp & 0xffffffffull) | ((uint64_t)dwdata << 32);
                } else {
                    if (a == CLINT_MSIP) rdata = msip;
                    else if (a == CLINT_CMP)      rdata = mtimecmp;
                    else if (a == CLINT_CMP + 4)  rdata = mtimecmp >> 32;
                    else if (a == CLINT_TIME)     rdata = mtime;
                    else if (a == CLINT_TIME + 4) rdata = mtime >> 32;
                }
            } else {
                if (dwe) mem.write(a, dwdata, dbe);
                else rdata = mem.read32(a);
                // riscv-tests: a store to `tohost` ends the test
                if (dwe && info.has_tohost && a == (info.tohost & ~3u) && (dbe & 1) && dwdata != 0)
                    exit_code = (dwdata == 1) ? 0 : (int)(dwdata >> 1);
            }
            dq.push_back({cycle + dlat, rdata});
        }
        mtime++;
    }

    if (trace) fclose(trace);
#if VM_TRACE
    if (tfp) tfp->close();
#endif
#if VM_COVERAGE
    {
        std::string cov = plusarg_str("cov");
        if (!cov.empty()) Verilated::threadContextp()->coveragep()->write(cov.c_str());
    }
#endif
    double ipc = cycle ? (double)retired / cycle : 0;
    if (exit_code < 0) {
        printf("TIMEOUT after %llu cycles (%llu retired)\n", (unsigned long long)cycle, (unsigned long long)retired);
        exit_code = 255;
    } else if (exit_code == 0) {
        printf("PASS  cycles=%llu instret=%llu IPC=%.3f\n", (unsigned long long)cycle, (unsigned long long)retired, ipc);
    } else {
        printf("FAIL  code=%d cycles=%llu instret=%llu\n", exit_code, (unsigned long long)cycle, (unsigned long long)retired);
    }
    delete top;
    return exit_code == 0 ? 0 : 1;
}
