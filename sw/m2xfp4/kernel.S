/* M2XFP4 dot-product kernels for the coprocessor (task 3).
 *
 *   uint32_t m2xfp4_dot_nacc1(const uint8_t *A, const uint8_t *W, const uint8_t *SA,
 *                             const uint8_t *SW, const uint8_t *AM, const uint8_t *WM,
 *                             uint32_t n_iter);
 *   void     m2xfp4_dot_nacc4(... same ..., uint32_t n_iter, uint32_t acc_out[4]);
 *
 * Same structure as sw/mxfp4/kernel.S, for a fair comparison: one loop
 * iteration = 2 blocks = 4 mxfused = 64 elements, n_iter = K / 64; group j of
 * the iteration -> accumulator j with NACC=4; scale packing once per block;
 * operands loaded at least 4 instructions before use; loop overhead = pointer
 * increments + 1 branch.
 *
 * Data layout (tb/scripts/gen_loop_data.py, --format m2xfp4): A, W two E2M1
 * elements per byte, low nibble first (instruction n = the word pair at byte
 * 8n); SA, SW one E8M0 byte per 32-element block; AM (Elem-EM, activations) and
 * WM (Sg-EM, weights) one byte per block, low nibble = the block's first
 * instruction, high nibble = its second, subgroup 0 in bits [1:0] of a nibble.
 *
 * mxfused M2XFP4 (funct3 = 011, funct2 = 10, opcode 0x0B): rs1 = activations,
 * rs2 = weights (fixed roles, mxdotp_pkg.sv ISA note); rs3 = pair {rs3+1 =
 * upper word, rs3 = FP32 acc}; rd = acc. Upper word = {7'b0, sg_em[3:0],
 * elem_em[3:0], 1'b0, b_scale, a_scale}: Sg-EM at [24:21], Elem-EM at [20:17]
 * (rs3[56:49], M2_ELEM_EM_LSB / M2_SG_EM_LSB), SW at [15:8], SA at [7:0].
 * Unlike MXFP4 the upper word differs per instruction (the metadata is per
 * instruction), so each instruction gets its own word:
 *   word0 = base | {sg nibble 0, elem nibble 0} << 17
 *   word1 = base | {sg nibble 1, elem nibble 1} << 17,   base = SW << 8 | SA.
 *
 * Registers:
 *   x5 pA, x6 pW, x7 pSA, x28 pSW, x24 pAM, x25 pWM, x29 = end of SA;
 *   x26 AM byte, x27 WM byte, x30 base, x31 scratch
 *   operands: set 0  A x10/x11  W x12/x13     set 1  A x14/x15  W x16/x17
 *   (acc, upper word) pairs: P0 x8/x9, P1 x18/x19, P2 x20/x21, P3 x22/x23
 *   The argument registers a4-a7 are operand registers, so the pointers are
 *   copied first and nacc4's acc_out (a7 = x17) is kept on the stack.
 * NACC=4 sends instruction j of the iteration to Pj (accumulator j sees
 * instructions j, j+4, ...). NACC=1 keeps one accumulator but alternates its
 * register: instruction 0 reads P0 and writes x20, instruction 1 reads P2 and
 * writes x8. Both upper words are therefore built before the pair, in x9 and
 * x21, and no instruction sits between the two MX instructions (a mv there
 * would reach the second one's dual read through WB->ID forwarding, which is
 * not proven - handoff limitation 7). Same accumulation order as one register.
 *
 * MX followed by a non-memory instruction (xif_lsu_stall, MXR4DOT question 10):
 * the MX pair of the first block is followed by the pSA addi moved up from the
 * loop tail (the second block's SA offset compensates), the second block's by
 * the loop tail.
 */

#define MXFUSED_M2XFP4(rd, rs1, rs2, rs3)  .insn r4 0x0B, 3, 2, rd, rs1, rs2, rs3

/* One block = 2 instructions. off = byte offset of the block's first
 * instruction in A/W; sidxa / sidxw / midx = offsets of its SA / SW / AM-WM
 * bytes from x7 / x28 / x24-x25; instruction 0: rd d0, rs3 pair a0 (upper word
 * w0 = a0 + 1); instruction 1: rd d1, rs3 pair a1 (upper word w1). */
.macro BLOCKM off, sidxa, sidxw, midx, d0, a0, w0, d1, a1, w1
  lw    x10, \off+0(x5)
  lw    x11, \off+4(x5)
  lw    x12, \off+0(x6)
  lw    x13, \off+4(x6)
  lw    x14, \off+8(x5)
  lw    x15, \off+12(x5)
  lw    x16, \off+8(x6)
  lw    x17, \off+12(x6)
  lbu   x30, \sidxa(x7)
  lbu   x31, \sidxw(x28)
  lbu   x26, \midx(x24)
  lbu   x27, \midx(x25)
  slli  x31, x31, 8
  or    x30, x30, x31       /* base = {SW, SA} */
  andi  \w0, x26, 15        /* instruction 0: Elem-EM nibble */
  andi  x31, x27, 15        /*                Sg-EM nibble */
  slli  x31, x31, 4
  or    \w0, \w0, x31
  slli  \w0, \w0, 17
  or    \w0, \w0, x30       /* word0 */
  srli  \w1, x26, 4         /* instruction 1: Elem-EM nibble */
  andi  x31, x27, 0xF0      /*                Sg-EM nibble << 4 */
  or    \w1, \w1, x31
  slli  \w1, \w1, 17
  or    \w1, \w1, x30       /* word1 */
  MXFUSED_M2XFP4(\d0, x10, x12, \a0)
  MXFUSED_M2XFP4(\d1, x14, x16, \a1)
.endm

.macro PROLOGUE
  addi  sp, sp, -64
  sw    a7, 48(sp)          /* acc_out (nacc4): a7 = x17 is an operand register */
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
  mv    x28, a3
  mv    x24, a4
  mv    x25, a5
  slli  x29, a6, 1          /* 2 scale bytes per iteration */
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
  addi  x28, x28, 2
  addi  x24, x24, 2
  addi  x25, x25, 2
  bne   x7, x29, 1b
.endm

  .text
  .globl m2xfp4_dot_nacc1
  .balign 4
m2xfp4_dot_nacc1:
  PROLOGUE
1:
  BLOCKM  0,  0, 0, 0, x20, x8, x9, x8, x20, x21
  addi  x7, x7, 2           /* moved up: non-memory instruction after the MX pair */
  BLOCKM 16, -1, 1, 1, x20, x8, x9, x8, x20, x21
  ADVANCE
  mv    a0, x8
  EPILOGUE

  .globl m2xfp4_dot_nacc4
  .balign 4
m2xfp4_dot_nacc4:
  PROLOGUE
1:
  BLOCKM  0,  0, 0, 0, x8,  x8,  x9,  x18, x18, x19
  addi  x7, x7, 2           /* moved up: non-memory instruction after the MX pair */
  BLOCKM 16, -1, 1, 1, x20, x20, x21, x22, x22, x23
  ADVANCE
  lw    x30, 48(sp)
  sw    x8,  0(x30)
  sw    x18, 4(x30)
  sw    x20, 8(x30)
  sw    x22, 12(x30)
  EPILOGUE
