// irq_test.c - directed test for machine timer / software interrupts.
//
// Added after code coverage showed timer/software interrupts and vectored
// mtvec mode were never exercised. Checks:
//   * vectored mtvec: each cause lands on its own vector table slot
//   * timer interrupt (CLINT mtimecmp) fires, is acknowledged by moving
//     mtimecmp, and does not fire while mie.MTIE = 0
//   * software interrupt (CLINT msip) fires and is cleared
//   * mcause / mepc values; execution resumes correctly after MRET
//   * writing mcycle
#include "bsp.h"

volatile uint32_t timer_hits, soft_hits, bad_hits, last_mcause, last_mepc;

// Vector table: mtvec.MODE = 1 -> interrupt with cause N jumps to base + 4*N.
// Slot 0 is also the target for all exceptions.
__asm__(
    "    .section .text\n"
    "    .align 6\n"
    "    .option push\n"
    "    .option norvc\n"        /* each slot must be exactly 4 bytes */
    "    .globl vec_table\n"
    "vec_table:\n"
    "    j bad_isr\n"          /* 0: exceptions */
    "    j bad_isr\n"          /* 1 */
    "    j bad_isr\n"          /* 2 */
    "    j soft_isr_entry\n"   /* 3: machine software interrupt */
    "    j bad_isr\n"          /* 4 */
    "    j bad_isr\n"          /* 5 */
    "    j bad_isr\n"          /* 6 */
    "    j timer_isr_entry\n"  /* 7: machine timer interrupt */
    "    j bad_isr\n"          /* 8 */
    "    j bad_isr\n"          /* 9 */
    "    j bad_isr\n"          /* 10 */
    "    j bad_isr\n"          /* 11: machine external interrupt */
    "    .option pop\n"
);

#define ISR_WRAPPER(name, handler)                                                   \
    __asm__("    .align 2\n" #name ":\n"                                            \
            "    addi sp, sp, -64\n"                                                \
            "    sw ra, 0(sp)\n sw t0, 4(sp)\n sw t1, 8(sp)\n sw t2, 12(sp)\n"      \
            "    sw a0, 16(sp)\n sw a1, 20(sp)\n sw a2, 24(sp)\n sw a3, 28(sp)\n"   \
            "    sw a4, 32(sp)\n sw a5, 36(sp)\n sw t3, 40(sp)\n sw t4, 44(sp)\n"   \
            "    sw t5, 48(sp)\n sw t6, 52(sp)\n sw a6, 56(sp)\n sw a7, 60(sp)\n"   \
            "    call " #handler "\n"                                               \
            "    lw ra, 0(sp)\n lw t0, 4(sp)\n lw t1, 8(sp)\n lw t2, 12(sp)\n"      \
            "    lw a0, 16(sp)\n lw a1, 20(sp)\n lw a2, 24(sp)\n lw a3, 28(sp)\n"   \
            "    lw a4, 32(sp)\n lw a5, 36(sp)\n lw t3, 40(sp)\n lw t4, 44(sp)\n"   \
            "    lw t5, 48(sp)\n lw t6, 52(sp)\n lw a6, 56(sp)\n lw a7, 60(sp)\n"   \
            "    addi sp, sp, 64\n"                                                 \
            "    mret\n")

static void set_timer(uint64_t when) {
    CLINT_MTIMECMP_HI = 0xffffffff;          // avoid a spurious match while updating
    CLINT_MTIMECMP_LO = (uint32_t)when;
    CLINT_MTIMECMP_HI = (uint32_t)(when >> 32);
}
static uint64_t mtime(void) {
    uint32_t hi, lo;
    do { hi = CLINT_MTIME_HI; lo = CLINT_MTIME_LO; } while (hi != CLINT_MTIME_HI);
    return ((uint64_t)hi << 32) | lo;
}

void timer_isr(void) {
    last_mcause = read_csr(mcause);
    last_mepc = read_csr(mepc);
    timer_hits++;
    set_timer(~0ull);                        // acknowledge: push mtimecmp away
}
void soft_isr(void) {
    last_mcause = read_csr(mcause);
    soft_hits++;
    CLINT_MSIP = 0;                          // acknowledge
}
void bad_handler(void) { bad_hits++; exit(90 + (read_csr(mcause) & 0xf)); }

ISR_WRAPPER(timer_isr_entry, timer_isr);
ISR_WRAPPER(soft_isr_entry, soft_isr);
ISR_WRAPPER(bad_isr, bad_handler);

extern char vec_table[];

#define CHECK(c, code) do { if (!(c)) { uart_puts("FAIL " #c "\n"); exit(code); } } while (0)

int main(void) {
    write_csr(mtvec, (uint32_t)vec_table | 1);          // vectored mode
    CHECK((read_csr(mtvec) & 3) == 1, 1);
    write_csr(mie, (1 << 7) | (1 << 3));                // MTIE | MSIE
    __asm__ volatile("csrsi mstatus, 8");                // MIE

    // ---- timer interrupt
    set_timer(mtime() + 200);
    uint64_t t0 = mtime();
    while (timer_hits == 0 && mtime() - t0 < 100000) ;
    CHECK(timer_hits == 1, 2);
    CHECK(last_mcause == 0x80000007, 3);
    CHECK(last_mepc != 0, 4);

    // ---- masked timer: MTIE = 0 -> must not fire
    write_csr(mie, (1 << 3));
    set_timer(mtime() + 50);
    t0 = mtime();
    while (mtime() - t0 < 2000) ;
    CHECK(timer_hits == 1, 5);
    CHECK(read_csr(mip) & (1 << 7), 6);                 // pending but masked
    write_csr(mie, (1 << 7) | (1 << 3));                // unmask -> fires now
    for (volatile int i = 0; i < 100; i++) ;
    CHECK(timer_hits == 2, 7);

    // ---- software interrupt
    CLINT_MSIP = 1;
    for (volatile int i = 0; i < 100; i++) ;
    CHECK(soft_hits == 1, 8);
    CHECK(last_mcause == 0x80000003, 9);

    // ---- global disable: MIE = 0 holds off the interrupt
    __asm__ volatile("csrci mstatus, 8");
    CLINT_MSIP = 1;
    for (volatile int i = 0; i < 50; i++) ;
    CHECK(soft_hits == 1, 10);
    __asm__ volatile("csrsi mstatus, 8");
    for (volatile int i = 0; i < 50; i++) ;
    CHECK(soft_hits == 2, 11);

    // ---- mcycle is writable
    write_csr(mcycle, 0);
    write_csr(mcycleh, 0);
    uint32_t c = read_csr(mcycle);
    CHECK(c < 1000, 12);

    CHECK(bad_hits == 0, 13);
    uart_puts("irq_test: all checks passed\n");
    return 0;
}
