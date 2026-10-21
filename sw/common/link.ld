/* Program-image build (make loop): everything in one 128 KB RAM at 0x0, which
 * is also the core's boot address (tb_mxdotp_core.sv boot_addr_i) and matches
 * tb/mem_model.sv MEM_BYTES. The stack grows down from the top of RAM. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 128K
}

SECTIONS
{
  .text : {
    KEEP(*(.text.init))
    *(.text .text.*)
  } > RAM

  .rodata : ALIGN(8) { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data   : ALIGN(8) { *(.data .data.* .sdata .sdata.*) } > RAM
  .bss    : ALIGN(8) { *(.bss .bss.* .sbss .sbss.* COMMON) } > RAM

  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
