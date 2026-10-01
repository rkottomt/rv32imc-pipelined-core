// util.h - shim so the riscv-tests Dhrystone builds against our BSP
#pragma once
#include <stdio.h>
#include <string.h>
#include "../common/bsp.h"
#define debug_printf printf
static uint32_t __c0, __i0;
static inline void setStats(int enable) {
    if (enable) { __c0 = read_csr(mcycle); __i0 = read_csr(minstret); }
    else printf("STATS cycles=%lu instret=%lu runs=%d\n",
                (unsigned long)(read_csr(mcycle) - __c0), (unsigned long)(read_csr(minstret) - __i0), NUMBER_OF_RUNS);
}
