/* Startup for the program-image build (make loop).
 *   - stack at the top of RAM (link.ld)
 *   - mtvec -> trap handler, so a fault ends the run with a recognisable exit
 *     code instead of silently restarting at 0 (mtvec_addr_i is 0 in the TB)
 *   - mcountinhibit cleared: CV32E40X resets it to all-ones, so mcycle and
 *     minstret would not count otherwise (cv32e40x_cs_registers.sv)
 *   - main()'s return value is written to the EXIT register (0 = pass)
 * .bss needs no clearing: mem_model.sv zeroes all RAM before loading the image. */
#include "mmio.h"

  .section .text.init, "ax"
  .globl _start
_start:
  la    sp, __stack_top
  la    t0, trap_handler
  csrw  mtvec, t0
  csrw  mcountinhibit, zero
  call  main
  li    t0, MMIO_EXIT
  sw    a0, 0(t0)
1:j     1b

/* Exit code 0xBAD0_00cc, cc = mcause[7:0]; mepc and mtval go to PUTHEX first.
 * 256-byte aligned: CV32E40X keeps only mtvec[31:8] as the base
 * (cv32e40x_cs_registers.sv), so a less-aligned handler would be truncated
 * to an address inside _start and the program would silently restart. */
  .align 8
trap_handler:
  li    t0, MMIO_PUTHEX
  csrr  t1, mepc
  sw    t1, 0(t0)
  csrr  t1, mtval
  sw    t1, 0(t0)
  csrr  t1, mcause
  andi  t1, t1, 0xff
  li    t2, 0xBAD00000
  or    t1, t1, t2
  li    t0, MMIO_EXIT
  sw    t1, 0(t0)
2:j     2b
