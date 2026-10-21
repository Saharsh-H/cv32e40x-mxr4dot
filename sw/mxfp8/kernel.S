/* MXFP8 (E4M3) dot-product kernels for the coprocessor (task 3).
 *
 *   uint32_t mxfp8_dot_nacc1(const uint8_t *A, const uint8_t *W,
 *                            const uint8_t *SA, const uint8_t *SW, uint32_t n_iter);
 *   void     mxfp8_dot_nacc4(const uint8_t *A, const uint8_t *W,
 *                            const uint8_t *SA, const uint8_t *SW, uint32_t n_iter,
 *                            uint32_t acc_out[4]);
 *
 * Same structure as sw/mxfp4/kernel.S, for a fair comparison: one loop
 * iteration = 4 mxfused, 4 lw per mxfused, scale packing once per 32-element
 * block (lbu, lbu, slli, or), instruction j of the iteration -> accumulator
 * pair Pj for NACC=4 (P0 for all with NACC=1), 5 instructions of loop
 * overhead, the same registers. Difference forced by the format: an E4M3
 * operand pair holds 8 elements, so one 32-element block is exactly the 4
 * instructions of an iteration (one scale word, copied into all four pairs
 * with NACC=4), and n_iter = K / 32.
 *
 * Data layout (tb/scripts/gen_loop_data.py): A, W one E4M3 byte per element,
 * instruction n's operand = the word pair at byte offset 8n; SA, SW one E8M0
 * byte per block. mxfused MXFP8: funct3 = 011, funct2 = 11; rs3[48] = 0
 * selects E4M3 (the scale word's bit 16 is 0).
 *
 * Registers: x5 pA, x6 pW, x7 pSA, x28 pSW, x29 end of SA, x30/x31 scratch;
 * operands set 0 A x10/x11 W x12/x13, set 1 A x14/x15 W x16/x17;
 * (acc, scale) pairs P0 x8/x9, P1 x18/x19, P2 x20/x21, P3 x22/x23.
 * nacc4's acc_out pointer (a5 = x15, an operand register) is kept on the stack.
 * Scheduling: the high words (rs+1, the dual-read companion ports) of every
 * operand are loaded at least 4 instructions before their mxfused; within
 * the second half of a block the low words are loaded last, so only base-port
 * forwarding can be involved (dual-read companion forwarding is only proven
 * EX->ID; handoff_project limitation 7).
 */

#define MXFUSED_MXFP8(rd, rs1, rs2, rs3)  .insn r4 0x0B, 3, 3, rd, rs1, rs2, rs3

/* One block = 4 instructions; d0..d3 = accumulators, s0r..s3r = their scale
 * registers (all equal with NACC=1). */
.macro BLOCK8 d0, s0r, d1, s1r, d2, s2r, d3, s3r
  lw    x10, 0(x5)
  lw    x11, 4(x5)
  lw    x12, 0(x6)
  lw    x13, 4(x6)
  lw    x14, 8(x5)
  lw    x15, 12(x5)
  lw    x16, 8(x6)
  lw    x17, 12(x6)
  lbu   x30, 0(x7)
  lbu   x31, 0(x28)
  slli  x31, x31, 8
  or    \s0r, x30, x31
  .ifnc \s1r, \s0r
  mv    \s1r, \s0r
  mv    \s2r, \s0r
  mv    \s3r, \s0r
  .endif
  MXFUSED_MXFP8(\d0, x10, x12, \d0)
  MXFUSED_MXFP8(\d1, x14, x16, \d1)
  lw    x11, 20(x5)
  lw    x13, 20(x6)
  lw    x10, 16(x5)
  lw    x12, 16(x6)
  lw    x15, 28(x5)
  lw    x17, 28(x6)
  lw    x14, 24(x5)
  lw    x16, 24(x6)
  MXFUSED_MXFP8(\d2, x10, x12, \d2)
  MXFUSED_MXFP8(\d3, x14, x16, \d3)
.endm

.macro PROLOGUE
  addi  sp, sp, -48
  sw    a5, 32(sp)
  sw    s0, 0(sp)
  sw    s1, 4(sp)
  sw    s2, 8(sp)
  sw    s3, 12(sp)
  sw    s4, 16(sp)
  sw    s5, 20(sp)
  sw    s6, 24(sp)
  sw    s7, 28(sp)
  mv    x5, a0
  mv    x6, a1
  mv    x7, a2
  mv    x28, a3
  add   x29, a4, x7         /* 1 scale byte per iteration */
  li    x8, 0
  li    x18, 0
  li    x20, 0
  li    x22, 0
.endm

.macro EPILOGUE
  lw    s0, 0(sp)
  lw    s1, 4(sp)
  lw    s2, 8(sp)
  lw    s3, 12(sp)
  lw    s4, 16(sp)
  lw    s5, 20(sp)
  lw    s6, 24(sp)
  lw    s7, 28(sp)
  addi  sp, sp, 48
  ret
.endm

  .text
  .globl mxfp8_dot_nacc1
  .balign 4
mxfp8_dot_nacc1:
  PROLOGUE
1:
  BLOCK8 x8, x9, x8, x9, x8, x9, x8, x9
  addi  x5, x5, 32
  addi  x6, x6, 32
  addi  x7, x7, 1
  addi  x28, x28, 1
  bne   x7, x29, 1b
  mv    a0, x8
  EPILOGUE

  .globl mxfp8_dot_nacc4
  .balign 4
mxfp8_dot_nacc4:
  PROLOGUE
1:
  BLOCK8 x8, x9, x18, x19, x20, x21, x22, x23
  addi  x5, x5, 32
  addi  x6, x6, 32
  addi  x7, x7, 1
  addi  x28, x28, 1
  bne   x7, x29, 1b
  lw    x30, 32(sp)
  sw    x8,  0(x30)
  sw    x18, 4(x30)
  sw    x20, 8(x30)
  sw    x22, 12(x30)
  EPILOGUE
