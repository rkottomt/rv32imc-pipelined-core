# crt0.S - bare-metal startup for the SoC
    .section .text.init
    .globl _start
_start:
    la   sp, __stack_top
    la   t0, trap_entry
    csrw mtvec, t0
    # zero .bss
    la   t0, __bss_start
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:  call main
    call exit
3:  j    3b

    # weak default trap handler: report as failure
    .weak trap_entry
    .align 2
trap_entry:
    csrr a0, mcause
    addi a0, a0, 100
    call exit
    j trap_entry
