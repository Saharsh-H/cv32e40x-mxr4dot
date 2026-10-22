/* Open question 10, step 2: isolation test for the load re-issue.
 * Is a load in EX re-issued every cycle only when WB is held by an XIF
 * instruction, or also when WB is held by an ordinary load whose data
 * response is late (+dwait)?
 *
 *   A (MARK 1..2): lw x28 then lw x29 back to back, independent addresses;
 *                  with +dwait the first load waits in WB for its response
 *                  while the second sits in EX.
 *   B (MARK 3..4): mxfused (smoke-test operands: 16 x 1.0 . 16 x 1.0,
 *                  scales 1.0) then the same two lw, as in the hung MXFP4
 *                  loop (WB mxfused, EX lw, ID lw); the mxfused waits in WB
 *                  for its XIF result while the first lw sits in EX.
 * Each pattern 3 times, separated by nops so the windows do not overlap.
 * Loads read 0x11111111 / 0x22222222 (A and B: 3 x 0x33333333 = 0x99999999
 * each); the mxfused chain gives 16, 32, 48.
 * Returns 0 if every loaded value and the final accumulator are right,
 * else the number of the first failing check. */
#include "mmio.h"

#define MXFUSED_MXFP4(rd, rs1, rs2, rs3)  .insn r4 0x0B, 3, 0, rd, rs1, rs2, rs3
#define SEP  nop; nop; nop; nop; nop; nop; nop; nop

  .data
  .align 4
q10_data:
  .word 0x11111111, 0x22222222

  .text
  .globl main
main:
  la    t0, q10_data
  li    t1, MMIO_MARK
  li    x10, 0x22222222
  li    x11, 0x22222222
  li    x12, 0x22222222
  li    x13, 0x22222222
  li    x14, 0
  li    x15, 0x00007F7F
  li    t2, 1
  sw    t2, 0(t1)            /* MARK 1 */
  SEP

  /* A: load-held WB */
  lw    x28, 0(t0)
  lw    x29, 4(t0)
  SEP
  add   x30, x28, x29
  lw    x28, 0(t0)
  lw    x29, 4(t0)
  SEP
  add   x30, x30, x28
  add   x30, x30, x29
  lw    x28, 0(t0)
  lw    x29, 4(t0)
  SEP
  add   x30, x30, x28
  add   x30, x30, x29        /* 3 x 0x33333333 = 0x99999999 */
  li    t2, 2
  sw    t2, 0(t1)            /* MARK 2 */
  SEP
  li    t2, 3
  sw    t2, 0(t1)            /* MARK 3 */
  SEP

  /* B: X-held WB */
  MXFUSED_MXFP4(x14, x10, x12, x14)
  lw    x28, 0(t0)
  lw    x29, 4(t0)
  SEP
  add   x31, x28, x29
  MXFUSED_MXFP4(x14, x10, x12, x14)
  lw    x28, 0(t0)
  lw    x29, 4(t0)
  SEP
  add   x31, x31, x28
  add   x31, x31, x29
  MXFUSED_MXFP4(x14, x10, x12, x14)
  lw    x28, 0(t0)
  lw    x29, 4(t0)
  SEP
  add   x31, x31, x28
  add   x31, x31, x29        /* 3 x 0x33333333 = 0x99999999 */
  li    t2, 4
  sw    t2, 0(t1)            /* MARK 4 */

  li    t2, MMIO_PUTHEX
  sw    x30, 0(t2)
  sw    x31, 0(t2)
  sw    x14, 0(t2)
  li    t2, 0x99999999
  li    a0, 1
  bne   x30, t2, 1f
  li    t2, 0x99999999
  li    a0, 2
  bne   x31, t2, 1f
  li    t2, 0x42400000       /* 48.0 */
  li    a0, 3
  bne   x14, t2, 1f
  li    a0, 0
1:ret
