/* MXFP8 (E4M3) dot product in plain RV32IM code - the software baseline (task 3).
 *
 * Independent of the golden models and of the coprocessor: reads only the
 * operand arrays, decodes E4M3 itself, uses no expected values.
 *
 * Arithmetic, per 8-element group n (one mxfused's worth):
 *   each E4M3 element = M * 2^E with an integer M (8|mant for normals,
 *   mant for subnormals) and E = exp - 10 (normals) or -9 (subnormals);
 *   s = sum_i Ma_i * Mb_i * 2^(Ea_i + Eb_i + 18)   exact in int64 (every
 *       product is aligned to the smallest possible exponent, -18; the largest
 *       shift is 28, so |s| < 8 * 225 * 2^28 < 2^39)
 *   acc = RNE(acc + s * 2^(SA + SW - 254 - 18))     one rounding
 * The group sum needs up to 39 bits, so converting it to float first would be
 * a second rounding. add_exact_rne() therefore adds the exact int64 term to
 * the FP32 accumulator and rounds once (round to nearest, ties to even), the
 * same rounding as one mxfused - the result must equal the coprocessor's
 * single-accumulator result bit for bit while everything stays in the FP32
 * normal range (range errors are reported, not hidden).
 */
#include <stdint.h>

uint32_t mxfp8_sw_range_error;

static inline int msb64(uint64_t x)              /* x != 0 */
{
    return 63 - __builtin_clzll(x);
}

/* RNE(acc + s * 2^e) for FP32 bits acc (zero or normal), int64 s. */
static uint32_t add_exact_rne(uint32_t acc, int64_t s, int e)
{
    if (s == 0)
        return acc;

    /* operand B = s * 2^e */
    int      nb = s < 0;
    uint64_t mb = nb ? (uint64_t)(-s) : (uint64_t)s;
    int      xb = e;
    int      lb = 61 - msb64(mb);                /* MSB to bit 61: room for a carry */
    mb <<= lb;
    xb -= lb;

    int      na = (int)(acc >> 31);
    uint32_t ea = (acc >> 23) & 0xFF;
    uint64_t ma;
    int      xa;
    if ((acc & 0x7FFFFFFFu) == 0) {
        ma = 0;
        xa = xb;
    } else {
        if (ea == 0 || ea == 255) { mxfp8_sw_range_error = 1; return acc; }
        ma = ((uint64_t)(acc & 0x7FFFFF) | (1u << 23)) << 38;   /* MSB to bit 61 */
        xa = (int)ea - 150 - 38;
    }

    /* big = operand with the larger exponent; the other is shifted right,
     * every lost bit jammed into bit 0 (sticky) */
    int      nbig, nsm, xbig;
    uint64_t mbig, msm;
    if (ma == 0 || xb > xa || (xb == xa && mb > ma)) {
        nbig = nb; mbig = mb; xbig = xb; nsm = na; msm = ma;
        if (ma == 0) msm = 0;
        else {
            int d = xb - xa;
            msm = d > 62 ? 1 : (ma >> d) | ((ma & ((1ull << d) - 1)) != 0);
        }
    } else {
        nbig = na; mbig = ma; xbig = xa; nsm = nb;
        int d = xa - xb;
        msm = d > 62 ? 1 : (mb >> d) | ((mb & ((1ull << d) - 1)) != 0);
    }

    uint64_t r = (nbig == nsm) ? mbig + msm : mbig - msm;
    if (r == 0)
        return 0;                                 /* exact cancellation: +0 */

    /* round r to 24 bits, ties to even */
    int p  = msb64(r);
    int sh = p - 23;
    uint32_t m24;
    if (sh > 0) {
        uint64_t rem  = r & ((1ull << sh) - 1);
        uint64_t half = 1ull << (sh - 1);
        m24 = (uint32_t)(r >> sh);
        if (rem > half || (rem == half && (m24 & 1)))
            m24++;
        if (m24 == (1u << 24)) { m24 >>= 1; sh++; }
    } else {
        m24 = (uint32_t)(r << -sh);
    }
    int ebias = xbig + sh + 23 + 127;
    if (ebias < 1 || ebias > 254) { mxfp8_sw_range_error = 1; return acc; }
    return ((uint32_t)nbig << 31) | ((uint32_t)ebias << 23) | (m24 & 0x7FFFFF);
}

/* E4M3 byte -> integer mantissa and exponent + 18 (>= 0); sign in *neg */
static inline uint32_t e4m3_decode(uint8_t b, int *sh18, int *neg)
{
    uint32_t e = (b >> 3) & 0xF, m = b & 7;
    *neg = b >> 7;
    if (e == 15 && m == 7) mxfp8_sw_range_error = 1;    /* NaN code: never generated */
    if (e == 0) { *sh18 = 0; return m; }                 /* subnormal: E = -9  -> -9 + 9 */
    *sh18 = (int)e - 1; return 8 | m;                    /* normal:    E = e - 10 -> e - 1 */
}

uint32_t mxfp8_dot_sw(const uint8_t *A, const uint8_t *W,
                      const uint8_t *SA, const uint8_t *SW, uint32_t n_groups)
{
    uint32_t acc = 0;
    for (uint32_t n = 0; n < n_groups; n++) {
        const uint8_t *pa = A + 8 * n, *pw = W + 8 * n;
        int64_t s = 0;
        for (int i = 0; i < 8; i++) {
            int sa, sw, na, nw;
            uint32_t ma = e4m3_decode(pa[i], &sa, &na);
            uint32_t mw = e4m3_decode(pw[i], &sw, &nw);
            int64_t p = (int64_t)(ma * mw) << (sa + sw);   /* (Ea + 9) + (Eb + 9) = Ea + Eb + 18 */
            s += (na ^ nw) ? -p : p;
        }
        int e = (int)SA[n >> 2] + (int)SW[n >> 2] - 254 - 18;
        acc = add_exact_rne(acc, s, e);
    }
    return acc;
}
