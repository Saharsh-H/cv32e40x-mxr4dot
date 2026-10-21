/* MXFP4 dot-product kernels for the coprocessor (task 3).
 *
 *   uint32_t mxfp4_dot_nacc1(const uint8_t *A, const uint8_t *W,
 *                            const uint8_t *SA, const uint8_t *SW, uint32_t n_iter);
 *   void     mxfp4_dot_nacc4(const uint8_t *A, const uint8_t *W,
 *                            const uint8_t *SA, const uint8_t *SW, uint32_t n_iter,
 *                            uint32_t acc_out[4]);
 *
 * Data layout (tb/scripts/gen_loop_data.py): A, W hold two E2M1 elements per
 * byte, low nibble first, so instruction n's 64-bit operand is the word pair at
 * byte offset 8n; SA, SW hold one E8M0 byte per 32-element block (= 2
 * instructions). One loop iteration = 2 blocks = 4 mxfused = 64 elements, so
 * n_iter = K / 64. Accumulators start at +0.0.
 *
 * mxfused (funct3 = 011, funct2 = 00, opcode 0x0B): rs1/rs2 = 64-bit A/W
 * register pairs (rs, rs+1); rs3 = pair {rs3+1 = scale word, rs3 = FP32 acc};
 * rd = acc. Scale word = {16'b0, b_scale, a_scale} (rs3[47:40] = W, [39:32] = A).
 *
 * Registers:
 *   x5 pA, x6 pW, x7 pSA, x28 pSW, x29 = end of SA; x30/x31 scratch
 *   (the a0-a7 argument registers are reused for operands, so nacc4's acc_out
 *   pointer, arriving in a5, is kept on the stack)
 *   operands: set 0  A x10/x11  W x12/x13     set 1  A x14/x15  W x16/x17
 *   (acc, scale) pairs: P0 x8/x9, P1 x18/x19, P2 x20/x21, P3 x22/x23
 * NACC=1 uses P0 for all four instructions (each waits for the previous
 * result). NACC=4 sends instruction j of the iteration to Pj, so accumulator j
 * sees instructions n = j, j+4, j+8, ... - the order the generator models.
 *
 * Scheduling: each operand register is loaded at least 4 instructions before
 * the mxfused that reads it, so no load result is forwarded straight into the
 * coprocessor issue (dual-read forwarding is only proven EX->ID; see
 * CURRENT_STATE / handoff_project limitation 7).
 */

#define MXFUSED_MXFP4(rd, rs1, rs2, rs3)  .insn r4 0x0B, 3, 0, rd, rs1, rs2, rs3

/* One block = 2 instructions. off = byte offset of the block's first
 * instruction in A/W; sidx = index of its scale byte; d0/d1 = accumulators of
 * the two instructions; s0r/s1r = the scale registers of those pairs. */
.macro BLOCK off, sidx, d0, s0r, d1, s1r
  lw    x10, \off+0(x5)
  lw    x11, \off+4(x5)
  lw    x12, \off+0(x6)
  lw    x13, \off+4(x6)
  lw    x14, \off+8(x5)
  lw    x15, \off+12(x5)
  lw    x16, \off+8(x6)
  lw    x17, \off+12(x6)
  lbu   x30, \sidx(x7)
  lbu   x31, \sidx(x28)
  slli  x31, x31, 8
  or    \s0r, x30, x31
  .ifnc \s1r, \s0r
  mv    \s1r, \s0r
  .endif
  MXFUSED_MXFP4(\d0, x10, x12, \d0)
  MXFUSED_MXFP4(\d1, x14, x16, \d1)
.endm

.macro PROLOGUE
  addi  sp, sp, -48
  sw    a5, 32(sp)          /* acc_out (nacc4): a5 = x15 is an operand register */
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
  slli  x29, a4, 1          /* 2 scale bytes per iteration */
  add   x29, x29, x7
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
  .globl mxfp4_dot_nacc1
  .balign 4
mxfp4_dot_nacc1:
  PROLOGUE
1:
  BLOCK  0, 0, x8, x9, x8, x9
  BLOCK 16, 1, x8, x9, x8, x9
  addi  x5, x5, 32
  addi  x6, x6, 32
  addi  x7, x7, 2
  addi  x28, x28, 2
  bne   x7, x29, 1b
  mv    a0, x8
  EPILOGUE

  .globl mxfp4_dot_nacc4
  .balign 4
mxfp4_dot_nacc4:
  PROLOGUE
1:
  BLOCK  0, 0, x8,  x9,  x18, x19
  BLOCK 16, 1, x20, x21, x22, x23
  addi  x5, x5, 32
  addi  x6, x6, 32
  addi  x7, x7, 2
  addi  x28, x28, 2
  bne   x7, x29, 1b
  lw    x30, 32(sp)
  sw    x8,  0(x30)
  sw    x18, 4(x30)
  sw    x20, 8(x30)
  sw    x22, 12(x30)
  EPILOGUE
