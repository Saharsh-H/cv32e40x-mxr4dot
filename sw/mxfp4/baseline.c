/* MXFP4 dot product in plain RV32IM code - the software baseline (task 3).
 *
 * Independent of the golden models and of the coprocessor: it reads only the
 * operand arrays and uses its own E2M1 decode table. No expected values are
 * used here (main.c does the comparisons).
 *
 * Arithmetic, per 16-element group n (one mxfused's worth):
 *   s = sum_i (2 a_i) * (2 w_i)   exact in int32 (each factor is an integer in
 *                                 -12..12, so |s| <= 16 * 144)
 *   t = s * 2^(SA + SW - 254 - 2) exact: s converted to float exactly
 *                                 (|s| < 2^24), the power of two applied to the
 *                                 exponent field directly
 *   acc = acc + t                 one IEEE RNE rounding (libgcc __addsf3)
 * That is one rounding of (acc + exact group sum) per 16 elements, the same
 * rounding as one mxfused, so the result must equal the coprocessor's
 * single-accumulator result bit for bit (as long as everything stays in the
 * FP32 normal range; scale_exact() reports it if not).
 */
#include <stdint.h>

/* 2 * E2M1 value, by 4-bit code {sign, exp[1:0], mant} */
static const int8_t e2m1_x2[16] = { 0,  1,  2,  3,  4,  6,  8,  12,
                                    0, -1, -2, -3, -4, -6, -8, -12 };

uint32_t mxfp4_sw_range_error;   /* set if a scaled group left the normal range */

static inline uint32_t f2u(float f) { uint32_t u; __builtin_memcpy(&u, &f, 4); return u; }
static inline float    u2f(uint32_t u) { float f; __builtin_memcpy(&f, &u, 4); return f; }

/* t * 2^e for a nonzero normal t, exact as long as the result stays normal. */
static float scale_exact(float t, int e)
{
    uint32_t u = f2u(t);
    int exp = (int)((u >> 23) & 0xFF) + e;
    if (exp < 1 || exp > 254) {
        mxfp4_sw_range_error = 1;
        return 0.0f;
    }
    return u2f((u & ~(0xFFu << 23)) | ((uint32_t)exp << 23));
}

uint32_t mxfp4_dot_sw(const uint8_t *A, const uint8_t *W,
                      const uint8_t *SA, const uint8_t *SW, uint32_t n_groups)
{
    float acc = 0.0f;
    for (uint32_t n = 0; n < n_groups; n++) {
        const uint8_t *pa = A + 8 * n, *pw = W + 8 * n;
        int32_t s = 0;
        for (int j = 0; j < 8; j++) {
            uint8_t a = pa[j], w = pw[j];
            s += e2m1_x2[a & 0xF] * e2m1_x2[w & 0xF];
            s += e2m1_x2[a >> 4]  * e2m1_x2[w >> 4];
        }
        if (s != 0) {
            int e = (int)SA[n >> 1] + (int)SW[n >> 1] - 254 - 2;
            acc = acc + scale_exact((float)s, e);
        }
    }
    return f2u(acc);
}
