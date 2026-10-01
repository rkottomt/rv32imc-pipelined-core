// bsp.c - minimal runtime: UART output, exit, newlib syscall stubs
#include "bsp.h"
#include <sys/stat.h>
#include <errno.h>

void uart_putc(char c) {
    while (UART_STATUS & 1) ;
    UART_TX = (uint8_t)c;
}

void uart_puts(const char *s) { while (*s) uart_putc(*s++); }

void print_u32(uint32_t v) {
    char buf[11]; int i = 10; buf[i] = 0;
    do { buf[--i] = '0' + v % 10; v /= 10; } while (v);
    uart_puts(&buf[i]);
}

// "tohost" convention: 1 = pass, (code << 1) | 1 = fail
void exit(int code) {
    SIMCTRL = code == 0 ? 1 : ((uint32_t)code << 1) | 1;
    for (;;) ;
}
void _exit(int code) { exit(code); }

// ---- newlib stubs (printf etc. from newlib-nano)
int _write(int fd, const char *p, int n) { int i; (void)fd; for (i = 0; i < n; i++) { if (p[i] == '\n') uart_putc('\r'); uart_putc(p[i]); } return n; }
int _read(int fd, char *p, int n) { (void)fd; (void)p; (void)n; return 0; }
int _close(int fd) { (void)fd; return -1; }
int _lseek(int fd, int o, int w) { (void)fd; (void)o; (void)w; return 0; }
int _fstat(int fd, struct stat *st) { (void)fd; st->st_mode = S_IFCHR; return 0; }
int _isatty(int fd) { (void)fd; return 1; }
int _kill(int p, int s) { (void)p; (void)s; errno = EINVAL; return -1; }
int _getpid(void) { return 1; }
extern char _end[];
static char *heap_end;
void *_sbrk(int incr) {
    if (!heap_end) heap_end = _end;
    char *prev = heap_end;
    heap_end += incr;
    return prev;
}
