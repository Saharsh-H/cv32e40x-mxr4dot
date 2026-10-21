/* Smoke test for the program-image build (make loop PROG=smoke).
 * Checks the memory model and MMIO before any kernel relies on them:
 *   1. word / halfword / byte stores and loads (byte enables), incl. sign extension
 *   2. one mxfused MXFP4 through the coprocessor: A = B = 16 x 1.0, scales
 *      1.0/1.0, acc 0.0 -> 16.0 (0x41800000; same operands as Test 1's P)
 *   3. a soft-float add through libgcc (__addsf3): 1.5f + 2.25f = 3.75f
 *   4. mcycle / minstret count after crt0 clears mcountinhibit
 * Returns 0 (pass) or the number of the first failing check. */
#include <stdint.h>
#include "mmio.h"

static volatile uint32_t buf[4];

static uint32_t mxfused_mxfp4_unit(void)
{
    /* rs1 = {x11,x10} = A, rs2 = {x13,x12} = B, rs3 = {x15 = scales, x14 = acc}, rd = x14.
     * funct3 = 011 (FUSED), funct2 = 00 (MXFP4), opcode 0x0B (mxdotp_pkg.sv). */
    register uint32_t a_lo  asm("x10") = 0x22222222, a_hi asm("x11") = 0x22222222;
    register uint32_t b_lo  asm("x12") = 0x22222222, b_hi asm("x13") = 0x22222222;
    register uint32_t acc   asm("x14") = 0x00000000;
    register uint32_t scale asm("x15") = 0x00007F7F;     /* {rsvd, b_scale=127, a_scale=127} */
    __asm__ volatile (".insn r4 0x0B, 3, 0, x14, x10, x12, x14"
                      : "+r"(acc)
                      : "r"(a_lo), "r"(a_hi), "r"(b_lo), "r"(b_hi), "r"(scale));
    return acc;
}

int main(void)
{
    mark(1);

    /* 1: stores and loads at every width */
    buf[0] = 0x11223344;
    if (buf[0] != 0x11223344) return 1;
    ((volatile uint8_t *)buf)[1] = 0xAB;
    if (buf[0] != 0x1122AB44) return 2;
    ((volatile uint16_t *)buf)[1] = 0xCDEF;
    if (buf[0] != 0xCDEFAB44) return 3;
    if (((volatile int8_t *)buf)[1] != (int8_t)0xAB) return 4;
    if (((volatile uint16_t *)buf)[1] != 0xCDEF) return 5;
    puthex(buf[0]);

    /* 2: one MX instruction */
    uint32_t r = mxfused_mxfp4_unit();
    puthex(r);
    if (r != 0x41800000) return 6;

    /* 3: soft-float */
    volatile float x = 1.5f, y = 2.25f;
    float z = x + y;
    uint32_t zb;
    __builtin_memcpy(&zb, &z, 4);
    puthex(zb);
    if (zb != 0x40700000) return 7;

    /* 4: counters */
    uint32_t c0 = rd_mcycle(), i0 = rd_minstret();
    for (volatile int k = 0; k < 10; k++) ;
    uint32_t c1 = rd_mcycle(), i1 = rd_minstret();
    puthex(c1 - c0);
    puthex(i1 - i0);
    if (c1 == c0 || i1 == i0) return 8;

    mark(2);
    return 0;
}
