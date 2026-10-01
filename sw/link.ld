/* Linker script for bare-metal test programs run on the core-level testbench */
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text : { *(.text*) }
  . = ALIGN(16);
  .data : { *(.data*) *(.rodata*) *(.sdata*) }
  .bss : { *(.bss*) *(.sbss*) }
  _end = .;
}
