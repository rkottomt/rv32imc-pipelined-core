// bsp.h - board support for the rv_soc
#pragma once
#include <stdint.h>

#define UART_TX      (*(volatile uint32_t *)0x10000000)
#define UART_STATUS  (*(volatile uint32_t *)0x10000004)
#define GPIO_OUT     (*(volatile uint32_t *)0x10001000)
#define SIMCTRL      (*(volatile uint32_t *)0x10002000)
#define CLINT_MSIP   (*(volatile uint32_t *)0x02000000)
#define CLINT_MTIMECMP_LO (*(volatile uint32_t *)0x02004000)
#define CLINT_MTIMECMP_HI (*(volatile uint32_t *)0x02004004)
#define CLINT_MTIME_LO    (*(volatile uint32_t *)0x0200BFF8)
#define CLINT_MTIME_HI    (*(volatile uint32_t *)0x0200BFFC)

#define read_csr(r) ({ uint32_t __v; __asm__ volatile ("csrr %0, " #r : "=r"(__v)); __v; })
#define write_csr(r, v) __asm__ volatile ("csrw " #r ", %0" :: "r"(v))

static inline uint64_t rdcycle64(void) {
    uint32_t hi, lo, hi2;
    do { hi = read_csr(mcycleh); lo = read_csr(mcycle); hi2 = read_csr(mcycleh); } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

void uart_putc(char c);
void uart_puts(const char *s);
void print_u32(uint32_t v);
void exit(int code) __attribute__((noreturn));
