// hello.c - smoke test / FPGA demo firmware: prints, counts on the LEDs
#include "bsp.h"
int main(void) {
    uart_puts("Hello from rv32imc pipelined core!\n");
    uart_puts("mhartid=");  print_u32(read_csr(mhartid)); uart_puts("\n");
    for (int i = 0; i < 8; i++) GPIO_OUT = 1u << i;
    uart_puts("cycles=");   print_u32(read_csr(mcycle)); uart_puts("\n");
    return 0;
}
