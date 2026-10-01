/* Linker script for programs running on the SoC: 64 KiB RAM at 0x0.
   The riscv-tests ".tohost" word is placed on the simulation controller. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K }
SECTIONS
{
  .text.init : { *(.text.init) } > RAM
  .text : { *(.text*) } > RAM
  . = ALIGN(16);
  .rodata : { *(.rodata*) *(.srodata*) } > RAM
  .data : { *(.data*) *(.sdata*) } > RAM
  .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > RAM
  _end = .;
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
  .tohost 0x10002000 (NOLOAD) : { *(.tohost) }
}
