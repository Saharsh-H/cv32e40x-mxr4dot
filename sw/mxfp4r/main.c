/* MXFP4R (residue on activations) K = 4096 dot product: coprocessor NACC=1 and
 * NACC=4 in one image (make loop PROG=mxfp4r), task 3. No software baseline
 * (scope: baselines for MXFP4 and MXFP8 only).
 *
 * Same regions, MARK ids and PUTHEX stream as sw/mxfp4/main.c, without region
 * 30 and the baseline result (the result block is: nacc1, nacc4 acc0..3,
 * nacc4 sum). Exit code (0 = pass): 1 NACC=1 != golden, 2 an NACC=4
 * accumulator != golden, 4 NACC=4 combined != golden.
 */
#include <stdint.h>
#include "mmio.h"

#define K        4096u
#define N_ITER   (K / 64)   /* 4 groups (mxresdot + mxfinal) per iteration */

extern const uint8_t  mx_a[], mx_w[], mx_ar[], mx_sa[], mx_sar[], mx_sw[];
extern const uint32_t exp_nacc1, exp_nacc4[4], exp_nacc4_sum;

uint32_t mxfp4r_dot_nacc1(const uint8_t *A, const uint8_t *W, const uint8_t *AR,
                          const uint8_t *const scales[3], uint32_t n_iter);
void     mxfp4r_dot_nacc4(const uint8_t *A, const uint8_t *W, const uint8_t *AR,
                          const uint8_t *const scales[3], uint32_t n_iter, uint32_t acc_out[4]);

static inline uint32_t f2u(float f) { uint32_t u; __builtin_memcpy(&u, &f, 4); return u; }
static inline float    u2f(uint32_t u) { float f; __builtin_memcpy(&f, &u, 4); return f; }

static uint32_t c0, i0;
#define BEGIN(id)  do { c0 = rd_mcycle(); i0 = rd_minstret(); mark(id); } while (0)
#define END(id)    do { mark((id) + 1); uint32_t c1 = rd_mcycle(), i1 = rd_minstret(); \
                        puthex(0xC0DE0000u | (id)); puthex(c1 - c0); puthex(i1 - i0); } while (0)

static const uint8_t *const scales[3] = { mx_sa, mx_sar, mx_sw };

int main(void)
{
    uint32_t r1, r4[4], r4sum;

    BEGIN(90);
    END(90);

    BEGIN(10);
    r1 = mxfp4r_dot_nacc1(mx_a, mx_w, mx_ar, scales, N_ITER);
    END(10);

    BEGIN(20);
    mxfp4r_dot_nacc4(mx_a, mx_w, mx_ar, scales, N_ITER, r4);
    END(20);

    BEGIN(22);
    r4sum = f2u((u2f(r4[0]) + u2f(r4[1])) + (u2f(r4[2]) + u2f(r4[3])));
    END(22);

    puthex(0xC0DE00A0u);
    puthex(r1);
    for (int j = 0; j < 4; j++) puthex(r4[j]);
    puthex(r4sum);
    puthex(0xC0DE00E0u);
    puthex(exp_nacc1);
    for (int j = 0; j < 4; j++) puthex(exp_nacc4[j]);
    puthex(exp_nacc4_sum);

    int err = 0;
    if (r1 != exp_nacc1) err |= 1;
    for (int j = 0; j < 4; j++) if (r4[j] != exp_nacc4[j]) err |= 2;
    if (r4sum != exp_nacc4_sum) err |= 4;
    return err;
}
