/* Testbench MMIO registers (tb/mem_model.sv) and counter helpers.
 * Usable from C and from assembly (.S files are preprocessed). */
#ifndef MMIO_H
#define MMIO_H

#define MMIO_BASE   0x20000000
#define MMIO_EXIT   (MMIO_BASE + 0x0)   /* write: end of run, value = exit code (0 = pass) */
#define MMIO_PUTHEX (MMIO_BASE + 0x4)   /* write: testbench prints "[SW] 0x%08h"           */
#define MMIO_MARK   (MMIO_BASE + 0x8)   /* write: testbench prints "[MARK id] cyc=<cycle>" */

#ifndef __ASSEMBLER__
#include <stdint.h>

static inline void puthex(uint32_t v) { *(volatile uint32_t *)MMIO_PUTHEX = v; }
static inline void mark(uint32_t id)  { *(volatile uint32_t *)MMIO_MARK = id; }

static inline uint32_t rd_mcycle(void)   { uint32_t v; __asm__ volatile ("csrr %0, mcycle"   : "=r"(v)); return v; }
static inline uint32_t rd_minstret(void) { uint32_t v; __asm__ volatile ("csrr %0, minstret" : "=r"(v)); return v; }
#endif

#endif
