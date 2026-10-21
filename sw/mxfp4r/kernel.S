/* MXFP4R (residue on activations) dot-product kernels for the coprocessor (task 3).
 *
 *   uint32_t mxfp4r_dot_nacc1(const uint8_t *A, const uint8_t *W, const uint8_t *AR,
 *                             const uint8_t *scales[3] = {SA, SAR, SW}, uint32_t n_iter);
 *   void     mxfp4r_dot_nacc4(... same ..., uint32_t acc_out[4]);
 *
 * Same structure as sw/mxfp4/kernel.S, for a fair comparison: one loop
 * iteration = 4 groups = 2 blocks = 64 elements; group j of the iteration ->
 * accumulator j with NACC=4 (all to one accumulator with NACC=1); scale
 * packing once per block; operands loaded at least 4 instructions before use;
 * loop overhead = pointer increments + 1 branch. A group is an
 *   mxresdot  rs1 = A pair, rs2 = W pair, rs3 = AR pair, rd = x0   (no writeback)
 *   mxfinal   rs1 = {SA, SAR, SW, 0} (plain 32-bit), rs2 = acc, rd = acc
 * so per group 6 lw (3 operand pairs) and 2 MX instructions; per block the
 * 3-byte scale word takes 3 lbu + 3 slli + 2 or. Groups are strictly
 * interleaved (mxresdot, mxfinal, mxresdot, mxfinal, ...), so the mailbox
 * never holds more than one entry (MAILBOX_DEPTH rule, mxdotp_xif.sv).
 * mxresdot: funct3 = 000, mxfinal: funct3 = 001, both funct2 = 01.
 *
 * Registers: x5 pA, x6 pW, x7 pAR, x28 pSA, x29 pSAR, x19 pSW, x21 end of SA;
 * x30/x31/x23 scratch; x9 scale word; accumulators x8 (NACC=1) or
 * x8/x18/x20/x22 (NACC=4); operands set 0 A x10/x11 W x12/x13 AR x14/x15,
 * set 1 A x16/x17 W x24/x25 AR x26/x27. All of s0-s11 are saved. nacc4's
 * acc_out (a5 = x15) is kept on the stack.
 */

#define MXRESDOT(rs1, rs2, rs3)          .insn r4 0x0B, 0, 1, x0, rs1, rs2, rs3
#define MXFINAL(rd, rs1_scales, rs2_acc) .insn r4 0x0B, 1, 1, rd, rs1_scales, rs2_acc, x0

/* One block = 2 groups. off = byte offset of the block's first group in
 * A/W/AR; sidx = its scale index; d0/d1 = accumulators of the two groups. */
.macro BLOCKR off, sidx, d0, d1
  lw    x10, \off+0(x5)
  lw    x11, \off+4(x5)
  lw    x12, \off+0(x6)
  lw    x13, \off+4(x6)
  lw    x14, \off+0(x7)
  lw    x15, \off+4(x7)
  lw    x16, \off+8(x5)
  lw    x17, \off+12(x5)
  lw    x24, \off+8(x6)
  lw    x25, \off+12(x6)
  lw    x26, \off+8(x7)
  lw    x27, \off+12(x7)
  lbu   x30, \sidx(x28)
  lbu   x31, \sidx(x29)
  lbu   x23, \sidx(x19)
  slli  x30, x30, 24
  slli  x31, x31, 16
  slli  x23, x23, 8
  or    x30, x30, x31
  or    x9, x30, x23
  MXRESDOT(x10, x12, x14)
  MXFINAL(\d0, x9, \d0)
  MXRESDOT(x16, x24, x26)
  MXFINAL(\d1, x9, \d1)
.endm

.macro PROLOGUE
  addi  sp, sp, -64
  sw    a5, 48(sp)
  sw    s0, 0(sp)
  sw    s1, 4(sp)
  sw    s2, 8(sp)
  sw    s3, 12(sp)
  sw    s4, 16(sp)
  sw    s5, 20(sp)
  sw    s6, 24(sp)
  sw    s7, 28(sp)
  sw    s8, 32(sp)
  sw    s9, 36(sp)
  sw    s10, 40(sp)
  sw    s11, 44(sp)
  mv    x5, a0
  mv    x6, a1
  mv    x7, a2
  lw    x28, 0(a3)          /* SA  */
  lw    x29, 4(a3)          /* SAR */
  lw    x19, 8(a3)          /* SW  */
  slli  x21, a4, 1          /* 2 scale bytes per iteration */
  add   x21, x21, x28
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
  lw    s8, 32(sp)
  lw    s9, 36(sp)
  lw    s10, 40(sp)
  lw    s11, 44(sp)
  addi  sp, sp, 64
  ret
.endm

.macro ADVANCE
  addi  x5, x5, 32
  addi  x6, x6, 32
  addi  x7, x7, 32
  addi  x28, x28, 2
  addi  x29, x29, 2
  addi  x19, x19, 2
  bne   x28, x21, 1b
.endm

  .text
  .globl mxfp4r_dot_nacc1
  .balign 4
mxfp4r_dot_nacc1:
  PROLOGUE
1:
  BLOCKR  0, 0, x8, x8
  BLOCKR 16, 1, x8, x8
  ADVANCE
  mv    a0, x8
  EPILOGUE

  .globl mxfp4r_dot_nacc4
  .balign 4
mxfp4r_dot_nacc4:
  PROLOGUE
1:
  BLOCKR  0, 0, x8,  x18
  BLOCKR 16, 1, x20, x22
  ADVANCE
  lw    x30, 48(sp)
  sw    x8,  0(x30)
  sw    x18, 4(x30)
  sw    x20, 8(x30)
  sw    x22, 12(x30)
  EPILOGUE
