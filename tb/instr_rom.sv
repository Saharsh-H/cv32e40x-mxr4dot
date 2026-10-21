//==============================================================================
// File    : instr_rom.sv
// Project : MXDOTP XIF Coprocessor - Verification
//------------------------------------------------------------------------------
// Description:
//   Instruction memory for tb_mxdotp_core.sv. Everything you need to touch to
//   change the test program lives in the "Program" section below.
//
//   The *_VAL / *_EXPECTED localparams below are read hierarchically by the
//   testbench scoreboard (tb_mxdotp_core.sv), so changing the operands used
//   by the MXFUSED/MXDOTP/MXFINAL instructions under test only requires
//   editing this file - the scoreboard picks up new expected values
//   automatically.
//
//   Memory interface: same reset-gated, 1-cycle-latency OBI-style model as
//   before - see the original file header (git history) for the full
//   rationale (XSim time-0 crash avoidance).
//
//------------------------------------------------------------------------------
// Test vectors for this milestone: true overlap for the MXFUSED slot (see
// mxdotp_fused_engine.sv / mxdotp_xif.sv's own milestone headers). Every
// prior test in this program only ever had ONE instruction of any given
// kind outstanding at a time - which is exactly the case that already
// worked before this milestone, and proves nothing new about it. Test 1
// below is rebuilt to actually exercise overlap: three MXFUSED instructions
// (P, Q, R) issued back-to-back, with no intervening instructions between
// them, so that by the time Q is issued, P is still mid-flight through the
// engine's own pipeline - and likewise for R.
//
// Six tests run in sequence (Test 5 and Test 6 are described next to their
// register assignments further down):
//
//   1) MXFUSED x3, back-to-back, MX_FMT_MXFP4 (plain, no residue):
//        P: A = B = {1.0 x16}, scales = 1.0/1.0, old_acc = 0.0
//           p1 = 16*(2*2) = 64, contrib1 = 64/4 = 16.0
//           Result = 16.0 -> 0x41800000 (same math the very first single-
//           instruction MXFUSED test used - see git history).
//        Q: A = B = {0.5 x16} (nibble 0x1), scales = 1.0/1.0, old_acc = 0.0
//           p1 = 16*(1*1) = 16, contrib1 = 16/4 = 4.0
//           Result = 4.0 -> 0x40800000.
//        R: A = {1.0 x16} (reuses P's A), B = {0.5 x16} (reuses Q's B),
//           scales = 1.0/1.0, old_acc = 100.0 (0x42C80000)
//           p1 = 16*(2*1) = 32, contrib1 = 32/4 = 8.0
//           Result = 100.0 + 8.0 = 108.0 -> 0x42D80000.
//        P/Q/R deliberately use three different destination registers and
//        three different operand combinations specifically so a mix-up
//        between simultaneously in-flight instructions (wrong id/rd, or -
//        the bug this milestone's own design review caught before writing
//        any RTL - a stale rs3 read belonging to a different instruction
//        than the one it's paired with) would show up as a wrong result,
//        not just a wrong result that happens to look right by coincidence.
//        All three expected values cross-checked against a Python port of
//        the exact bit-level algorithm, same as every other test here.
//
//   2) MX_FUNCT3_DUALREAD_TEST (validation-only, not part of the real
//      MXDOTP ISA - see mxdotp_execute.sv/mxdotp_pkg.sv): proves the core's
//      dual-read mechanism (cv32e40x_core.sv's X_DUALREAD) works in
//      isolation from the MXDOTP algorithm itself. x10/x11 (an adjacent
//      register pair) are loaded with distinct, easily-told-apart values;
//      the test instruction with rs1=x10 requests a paired read of
//      {x11,x10} and writes x11's value (the "+1"/upper half) to x12. The
//      write to x11 is placed with zero NOPs before the test instruction on
//      purpose, forcing the EX->ID forwarding path for the companion port.
//
//   3)+4) MXDOTP/MXFINAL, MX_FMT_MXFP4_RESIDUAL (k=16, with residue - the
//      only path these two instructions serve now):
//        A = B = {1.0 x16}, AR = {0.5 x16} (nibble 0x1 each)
//        a_scale = ar_scale = b_scale = 1.0 (E8M0 raw 127)
//        old accumulator = 0.0
//        p1 = 64 (as above), p2 = sum(code(AR_i)*code(B_i)) = 16*(1*2) = 32
//        contrib1 = 16.0, contrib2 = p2/4 = 8.0
//        Result = 0.0 + 16.0 + 8.0 = 24.0 -> FP32 0x41C00000.
//        Both expected values cross-checked against a Python port of the
//        exact bit-level algorithm (place_in_acc/fp32_to_acc/acc_to_fp32),
//        not just hand-derived.
//==============================================================================

module instr_rom
    import tb_pkg::*;
    import mxdotp_pkg::*;
#(
`ifdef MX_STREAM_TEST
  parameter int unsigned NUM_WORDS = 256 // stream program (make stream) is ~210 words
`else
  parameter int unsigned NUM_WORDS = 256 // power of 2 - instr_rdata_o's address decode
                                          // (addr_q[$clog2(NUM_WORDS)+1:2]) assumes that;
                                          // a non-power-of-2 NUM_WORDS would let that index
                                          // run past rom[]'s actual bound
`endif
)
(
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        instr_req_i,
  output logic        instr_gnt_o,
  output logic        instr_rvalid_o,
  input  logic [31:0] instr_addr_i,
  output logic [31:0] instr_rdata_o,
  output logic        instr_err_o
);

  //----------------------------------------------------------------------------
  // Program - edit only below this line to change the test.
  //----------------------------------------------------------------------------

  //----------------------------------------------------------------------------
  // Test 1: MXFUSED x3 back-to-back (P, Q, R), MX_FMT_MXFP4 (plain, no
  // residue - the fast path). Register assignment below; see file header
  // for the math each one checks.
  //----------------------------------------------------------------------------
  localparam logic [4:0] REG_FA_BASE   = 5'd1;  // x1 (lo) / x2 (hi): P's A (reused as R's A)
  localparam logic [4:0] REG_FB_BASE   = 5'd3;  // x3 (lo) / x4 (hi): P's B
  localparam logic [4:0] REG_FRS3_BASE = 5'd5;  // x5 (lo)=old_acc / x6 (hi)={reserved,b_scale,a_scale}: P's rs3 (reused as Q's rs3 - same old_acc=0.0/scales=1.0)
  localparam logic [4:0] REG_FRESULT   = 5'd9;  // x9: P's rd

  localparam logic [4:0] REG_QA_BASE   = 5'd22; // x22 (lo) / x23 (hi): Q's A
  localparam logic [4:0] REG_QB_BASE   = 5'd24; // x24 (lo) / x25 (hi): Q's B (reused as R's B)
  localparam logic [4:0] REG_QRESULT   = 5'd28; // x28: Q's rd

  localparam logic [4:0] REG_RRS3_BASE = 5'd29; // x29 (lo) / x30 (hi): R's rs3 (different old_acc, needs its own)
  localparam logic [4:0] REG_RRESULT   = 5'd31; // x31: R's rd

  localparam logic [3:0]  MXFP4_ONE  = 4'h2; // E2M1 encoding of 1.0 (sign=0,exp=01,mant=0)
  localparam logic [3:0]  MXFP4_HALF = 4'h1; // E2M1 encoding of 0.5 (sign=0,exp=00,mant=1)
  localparam logic [63:0] A_VAL      = {16{MXFP4_ONE}};   // 16x 1.0 -> 0x2222222222222222
  localparam logic [63:0] B_VAL      = {16{MXFP4_ONE}};   // 16x 1.0 -> 0x2222222222222222
  localparam logic [63:0] QA_VAL     = {16{MXFP4_HALF}};  // 16x 0.5 -> 0x1111111111111111
  localparam logic [63:0] QB_VAL     = {16{MXFP4_HALF}};  // 16x 0.5 -> 0x1111111111111111
  localparam logic [7:0]  E8M0_SCALE_ONE = 8'd127;        // 2^0 = 1.0

  // rs3 packing (see mxdotp_pkg.sv's MXFUSED funct3 comment): lower 32 bits
  // (base reg) = old_acc; upper 32 bits (companion reg) =
  // {reserved[15:0],b_scale[7:0],a_scale[7:0]}. Scales are 1.0/1.0 for all
  // of P/Q/R, so F_SCALES_HI_VAL is shared across all three rs3 values.
  localparam logic [31:0] F_OLD_ACC_VAL   = 32'h0000_0000;  // 0.0f - P's and Q's old_acc
  localparam logic [31:0] F_SCALES_HI_VAL = {16'd0, E8M0_SCALE_ONE, E8M0_SCALE_ONE}; // {reserved,b_scale,a_scale}
  localparam logic [63:0] FRS3_VAL        = {F_SCALES_HI_VAL, F_OLD_ACC_VAL};        // {hi,lo} - P's rs3, reused by Q

  localparam logic [31:0] R_OLD_ACC_VAL = 32'h42C8_0000;  // 100.0f - R's old_acc, the one thing
                                                            // that actually differs from P/Q's rs3
  localparam logic [63:0] RRS3_VAL      = {F_SCALES_HI_VAL, R_OLD_ACC_VAL};

  // Hand-computed, Python-cross-checked (see header) - not yet a full golden-model suite.
  // P: same math the very first single-instruction MXFUSED test used - see header.
  localparam logic [31:0] MXFP4_FUSED_EXPECTED   = 32'h4180_0000;  // 16.0f (P)
  localparam logic [31:0] MXFP4_FUSED_Q_EXPECTED = 32'h4080_0000;  //  4.0f (Q)
  localparam logic [31:0] MXFP4_FUSED_R_EXPECTED = 32'h42D8_0000;  // 108.0f (R)

  localparam logic [31:0] INSTR_MXFUSED = encode_r4(
    MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP4,
    REG_FRESULT, REG_FA_BASE, REG_FB_BASE, REG_FRS3_BASE
  );
  localparam logic [31:0] INSTR_MXFUSED_Q = encode_r4(
    MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP4,
    REG_QRESULT, REG_QA_BASE, REG_QB_BASE, REG_FRS3_BASE  // reuses P's rs3 registers - same value
  );
  localparam logic [31:0] INSTR_MXFUSED_R = encode_r4(
    MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP4,
    REG_RRESULT, REG_FA_BASE, REG_QB_BASE, REG_RRS3_BASE  // reuses P's A and Q's B registers
  );

  //----------------------------------------------------------------------------
  // Dual-read validation test (MX_FUNCT3_DUALREAD_TEST - not part of the real MXDOTP ISA,
  // see mxdotp_execute.sv/mxdotp_pkg.sv). REG_DR_BASE and REG_DR_BASE+1 are the adjacent
  // register pair the core reads as {hi,lo}; REG_DR_RESULT gets the "+1"/hi half.
  //----------------------------------------------------------------------------
  localparam logic [4:0] REG_DR_BASE   = 5'd10; // x10 (lo); x11 (=x10+1) is the implied hi half
  localparam logic [4:0] REG_DR_RESULT = 5'd12; // x12: MXDUALREAD_TEST rd

  localparam logic [31:0] DUALREAD_LO_VAL   = 32'hAAAA_AAAA; // x10 (rs1, the "lo" half)
  localparam logic [31:0] DUALREAD_HI_VAL   = 32'hBBBB_BBBB; // x11 (rs1+1, the "hi" half)
  localparam logic [31:0] DUALREAD_EXPECTED = DUALREAD_HI_VAL; // rd should end up == x11

  // rs2/rs3 are unused by MX_FUNCT3_DUALREAD_TEST's arithmetic - the interface's dualread
  // bit is global (dual-reads rs2/rs3 too, per its own semantics), but their values are
  // simply never looked at, so x0 is fine here.
  localparam logic [31:0] INSTR_MXDUALREAD_TEST = encode_r4(
    MX_OPCODE, MX_FUNCT3_DUALREAD_TEST, MX_FMT_MXFP4,
    REG_DR_RESULT, REG_DR_BASE, 5'd0 /*rs2 unused*/, 5'd0 /*rs3 unused*/
  );

  //----------------------------------------------------------------------------
  // Test 2: MX_FMT_MXFP4_RESIDUAL (k=16, with residue) register assignment -
  // the only format MXDOTP/MXFINAL serve any more (see header).
  //----------------------------------------------------------------------------
  localparam logic [4:0] REG_RA_BASE  = 5'd13; // x13 (lo) / x14 (hi): A
  localparam logic [4:0] REG_RB_BASE  = 5'd15; // x15 (lo) / x16 (hi): B
  localparam logic [4:0] REG_RAR_BASE = 5'd17; // x17 (lo) / x18 (hi): AR (residue, used)
  // x29/x30 rather than x19/x20: these held Test 1's R rs3, which R consumed
  // at issue (rom[26]) long before these loads run (rom[45..48]), so they are
  // free to reuse. That deliberately frees x19/x20 to be PRISTINE registers
  // for Test 4's destinations - see Test 4's header for why every test's
  // destination must be written exactly once in the whole program.
  localparam logic [4:0] REG_RSCALES  = 5'd29; // x29: {a_scale,ar_scale,b_scale,reserved}
  localparam logic [4:0] REG_ROLD_ACC = 5'd30; // x30: old FP32 accumulator
  localparam logic [4:0] REG_RRESULT_FINAL = 5'd21; // x21: MXFINAL rd (residual test - distinct
                                                      // name from Test 1's REG_RRESULT above)

  localparam logic [63:0] RA_VAL       = {16{MXFP4_ONE}};   // 16x 1.0 -> 0x2222222222222222
  localparam logic [63:0] RB_VAL       = {16{MXFP4_ONE}};   // 16x 1.0 -> 0x2222222222222222
  localparam logic [63:0] RAR_VAL      = {16{MXFP4_HALF}};  // 16x 0.5 -> 0x1111111111111111
  localparam logic [31:0] RSCALES_VAL  = {E8M0_SCALE_ONE, E8M0_SCALE_ONE, E8M0_SCALE_ONE, 8'd0};
  localparam logic [31:0] ROLD_ACC_VAL = 32'h0000_0000;    // 0.0f

  // Hand-computed, Python-cross-checked (see header) - not yet a full golden-model suite.
  localparam logic [31:0] MXFP4_RESIDUAL_EXPECTED = 32'h41C0_0000;  // 24.0f

  localparam logic [31:0] INSTR_MXDOTP_RESIDUAL = encode_r4(
    MX_OPCODE, MX_FUNCT3_DOTP, MX_FMT_MXFP4_RESIDUAL,
    5'd0 /*rd unused - no writeback*/, REG_RA_BASE, REG_RB_BASE, REG_RAR_BASE
  );

  localparam logic [31:0] INSTR_MXFINAL_RESIDUAL = encode_r4(
    MX_OPCODE, MX_FUNCT3_FINAL, MX_FMT_MXFP4_RESIDUAL,
    REG_RRESULT_FINAL, REG_RSCALES, REG_ROLD_ACC, 5'd0 /*rs3 unused*/
  );

  //----------------------------------------------------------------------------
  // Test 3: MXFP8 fast path (E4M3 + E5M2) AND cross-engine overlap. Three
  // back-to-back MXFUSED instructions of MIXED element formats, no gap:
  //   S: MXFP8 E4M3 (rs3[48]=0) -> the fp8 engine (order-queue slot FUSED8)
  //   M: MXFP4              -> the fp4 engine (order-queue slot FUSED)
  //   T: MXFP8 E5M2 (rs3[48]=1) -> the fp8 engine (order-queue slot FUSED8)
  // S and T run on the fp8 engine, M on the fp4 engine, concurrently - so this
  // exercises BOTH the MXFP8 arithmetic (E4M3 and E5M2) AND the two-slot order
  // queue interleaving results from two different engines back into program
  // order (S, then M, then T). Destinations x7/x8/x26 are written ONLY by
  // S/M/T (no load targets them), so the scoreboard's ordering monitor sees
  // exactly these three writebacks and nothing else.
  //
  //   S (E4M3): A = {4.0, 0.5, 1,1,1,1,1,1}, B = {1.0 x8}, scales 1.0/1.0,
  //             old_acc 0.0 -> 4 + 0.5 + 6 = 10.5 -> 0x41280000
  //   M (MXFP4): A = B = {1.0 x16}, scales 1.0/1.0, old_acc 0.0
  //              -> 16*(2*2)/4 = 16.0 -> 0x41800000
  //   T (E5M2): A = B = {1.0 x8}, scales 1.0/1.0, old_acc 0.0
  //             -> 8*(1*1) = 8.0 -> 0x41000000
  // All three cross-checked against a Python port of the exact bit-level
  // datapath (per-element decode -> product -> place_in_acc -> acc_finalize).
  //
  // Byte packing (fp8 engine unpacks rs1[8*i +: 8] for element i, so element 0
  // is the LOW byte): E4M3 1.0=0x38, 0.5=0x30, 4.0=0x48; E5M2 1.0=0x3C.
  //----------------------------------------------------------------------------
  localparam logic [4:0] REG_F8S_A_BASE  = 5'd1;  // x1/x2 : S's A (E4M3, mixed exponents)
  localparam logic [4:0] REG_F8S_B_BASE  = 5'd3;  // x3/x4 : S's B (E4M3, all 1.0)
  localparam logic [4:0] REG_F8_E4_RS3   = 5'd5;  // x5/x6 : rs3 for E4M3 (bit48=0); shared by M
  localparam logic [4:0] REG_F4M_AB_BASE = 5'd13; // x13/x14: M's A=B (MXFP4, all 1.0)
  localparam logic [4:0] REG_F8T_AB_BASE = 5'd22; // x22/x23: T's A=B (E5M2, all 1.0)
  localparam logic [4:0] REG_F8_E5_RS3   = 5'd24; // x24/x25: rs3 for E5M2 (bit48=1)

  localparam logic [4:0] REG_F8S_RESULT  = 5'd7;  // x7 : S's rd (MXFP8 E4M3)
  localparam logic [4:0] REG_F4M_RESULT  = 5'd8;  // x8 : M's rd (MXFP4)
  localparam logic [4:0] REG_F8T_RESULT  = 5'd26; // x26: T's rd (MXFP8 E5M2)

  localparam logic [63:0] F8S_A_VAL     = 64'h3838_3838_3838_3048; // elem0=4.0,elem1=0.5,elem2-7=1.0
  localparam logic [63:0] F8S_B_VAL     = 64'h3838_3838_3838_3838; // 8x 1.0 (E4M3)
  localparam logic [63:0] F8_E4_RS3_VAL = 64'h0000_7F7F_0000_0000; // {rsvd=0,b=127,a=127}/old_acc=0 -> bit48=0
  localparam logic [63:0] F4M_AB_VAL    = {16{MXFP4_ONE}};          // 16x 1.0 (MXFP4) = 0x2222...2222
  localparam logic [63:0] F8T_AB_VAL    = 64'h3C3C_3C3C_3C3C_3C3C;  // 8x 1.0 (E5M2)
  localparam logic [63:0] F8_E5_RS3_VAL = 64'h0001_7F7F_0000_0000; // rsvd[0]=1 -> bit48=1 -> E5M2

  // Hand-computed, Python-cross-checked (see header) - not yet a golden suite.
  localparam logic [31:0] MXFP8_S_EXPECTED = 32'h4128_0000;  // 10.5f (E4M3, mixed exponents)
  localparam logic [31:0] MXFP4_M_EXPECTED = 32'h4180_0000;  // 16.0f (MXFP4)
  localparam logic [31:0] MXFP8_T_EXPECTED = 32'h4100_0000;  //  8.0f (E5M2)

  localparam logic [31:0] INSTR_MXFUSED_F8S = encode_r4(
    MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP8,
    REG_F8S_RESULT, REG_F8S_A_BASE, REG_F8S_B_BASE, REG_F8_E4_RS3
  );
  localparam logic [31:0] INSTR_MXFUSED_F4M = encode_r4(
    MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP4,
    // A=B=x13 (same reg pair - both read {x14,x13}); rs3 shares S's E4M3 word,
    // which is fine because the MXFP4 engine ignores rs3[48].
    REG_F4M_RESULT, REG_F4M_AB_BASE, REG_F4M_AB_BASE, REG_F8_E4_RS3
  );
  localparam logic [31:0] INSTR_MXFUSED_F8T = encode_r4(
    MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP8,
    REG_F8T_RESULT, REG_F8T_AB_BASE, REG_F8T_AB_BASE, REG_F8_E5_RS3  // A=B=x22
  );

  //----------------------------------------------------------------------------
  // Test 4: M2XFP4 (metadata-augmented MXFP4) AND three-engine overlap. Three
  // back-to-back MXFUSED instructions, one per engine, no gap:
  //   U: M2XFP4 -> the m2 engine  (order-queue slot FUSED_M2)  <- the new path
  //   V: MXFP4  -> the fp4 engine (order-queue slot FUSED)
  //   W: MXFP8  -> the fp8 engine (order-queue slot FUSED8)
  // Test 3 already proved TWO engines interleave; this proves all THREE do,
  // which is what MX_NUM_SLOTS 5->6 / MX_ORDER_DEPTH 15->20 actually changed.
  //
  // U's operands are chosen to be DISCRIMINATING, not merely correct - each of
  // the three plausible wiring/decode bugs produces a DIFFERENT number, so a
  // bug fails loudly instead of passing by coincidence:
  //   * top-1 of subgroup 0 sits at index 2, NOT index 0, so the on-chip
  //     top-1 re-derivation is actually exercised (a hardwired index-0 or a
  //     highest-index tie-break gives a different answer).
  //   * plain MXFP4 on the IDENTICAL operands gives 21.0, not 29.875 - so if
  //     U were mis-routed to the fp4 engine (or M2XFP4 fell into its
  //     safe-inert SoP=0 stub) the result is wrong, not accidentally right.
  //   * elem_em/sg_em differ per subgroup ([3,3] / [1,2]), so swapping the two
  //     subgroups' metadata gives 31.3125, and dropping the Elem-EM promotion
  //     entirely gives 28.25.
  //
  //   U (M2XFP4): rs1 = A = {1,1,6,1,1,1,1,1 | 1,1,1,1,1,1,1,1} (ACTIVATIONS)
  //               rs2 = B = {1.0 x16}                            (WEIGHTS)
  //               elem_em = {sg1=3, sg0=3}, sg_em = {sg1=2, sg0=1}
  //               scales 1.0/1.0, old_acc 0.0
  //               sg0: top-1 = idx2 (6.0 -> X' = 7.0 via meta=11);
  //                    P0 = 7*(2*8) + 2*56 = 224/16 = 14.0; x1.25 = 17.5
  //               sg1: top-1 = idx0 (all tie -> lowest index; 1.0 -> X' = 1.25)
  //                    P1 = 7*(2*8) + 2*10 = 132/16 = 8.25;  x1.5  = 12.375
  //               Result = 17.5 + 12.375 = 29.875 -> 0x41EF0000
  //   V (MXFP4):  A = B = {1.0 x16} -> 16*(2*2)/4 = 16.0 -> 0x41800000
  //   W (MXFP8 E4M3): A = B = {1.0 x8} -> 8*(1*1) = 8.0 -> 0x41000000
  //
  // All three cross-checked against the golden models (m2_golden.py,
  // fp4_golden.py, fp8_golden.py) - not hand-derived.
  //
  // rs3 IS DELIBERATELY SHARED by all three (x5/x6). That is itself a check:
  // the same 64-bit word carries M2XFP4 metadata at [56:49], and the fp4
  // engine must ignore rs3[63:48] entirely while the fp8 engine must read only
  // rs3[48] (=0 -> E4M3) out of that range. If either engine mistook the
  // metadata bits for something of its own, V or W would be wrong.
  //
  // Destinations x27/x19/x20 are PRISTINE - nothing else in this program, load
  // or result, ever writes them. That is required, not incidental: the
  // scoreboard's writeback capture latches are first-write-wins, so a reused
  // destination would latch an earlier test's value. x19/x20 were freed for
  // this by moving Test 2's scales/old_acc to x29/x30 (see above).
  //----------------------------------------------------------------------------
  localparam logic [4:0] REG_M2U_A_BASE  = 5'd1;  // x1/x2  : U's A (activations, Elem-EM)
  localparam logic [4:0] REG_M2U_B_BASE  = 5'd3;  // x3/x4  : U's B (weights, Sg-EM)
  localparam logic [4:0] REG_M2_RS3      = 5'd5;  // x5/x6  : rs3 - SHARED by U, V and W
  localparam logic [4:0] REG_M2V_AB_BASE = 5'd13; // x13/x14: V's A=B (MXFP4, all 1.0)
  localparam logic [4:0] REG_M2W_AB_BASE = 5'd22; // x22/x23: W's A=B (E4M3, all 1.0)

  localparam logic [4:0] REG_M2U_RESULT  = 5'd27; // x27: U's rd (M2XFP4) - pristine
  localparam logic [4:0] REG_M2V_RESULT  = 5'd19; // x19: V's rd (MXFP4)  - pristine (freed above)
  localparam logic [4:0] REG_M2W_RESULT  = 5'd20; // x20: W's rd (MXFP8)  - pristine (freed above)

  localparam logic [3:0]  MXFP4_SIX = 4'h7; // E2M1 encoding of 6.0 (sign=0,exp=11,mant=1)

  // A: nibble i occupies bits [4i+3:4i], so element 0 is the LOW nibble.
  // Element 2 = 6.0 makes subgroup 0's top-1 land at index 2.
  localparam logic [63:0] M2U_A_VAL  = 64'h2222_2222_2222_2722; // sg0: 1,1,6,1,1,1,1,1 | sg1: 1 x8
  localparam logic [63:0] M2U_B_VAL  = {16{MXFP4_ONE}};          // 16x 1.0 (weights)
  localparam logic [63:0] M2V_AB_VAL = {16{MXFP4_ONE}};          // 16x 1.0 (MXFP4)
  localparam logic [63:0] M2W_AB_VAL = 64'h3838_3838_3838_3838;  // 8x 1.0 (E4M3)

  // rs3 upper word: {rsvd[6:0]=0, sg_em[3:0], elem_em[3:0], bit48=0, b_scale, a_scale}
  // -> word bits: [24:21]=sg_em, [20:17]=elem_em, [16]=sub-format select (0 =
  // E4M3 for the fp8 engine; kept 0 for M2XFP4, which reserves it uniformly).
  // sg_em = {sg1=2, sg0=1} = 4'b1001 ; elem_em = {sg1=3, sg0=3} = 4'b1111
  localparam logic [3:0]  M2_SG_EM   = 4'b1001;  // {subgroup1=2, subgroup0=1}
  localparam logic [3:0]  M2_ELEM_EM = 4'b1111;  // {subgroup1=3, subgroup0=3}
  localparam logic [31:0] M2_RS3_HI_VAL = {7'd0, M2_SG_EM, M2_ELEM_EM, 1'b0,
                                            E8M0_SCALE_ONE, E8M0_SCALE_ONE}; // = 0x013E7F7F
  localparam logic [63:0] M2_RS3_VAL    = {M2_RS3_HI_VAL, 32'h0000_0000};    // old_acc = 0.0

  // Golden-model cross-checked (see header) - m2/fp4/fp8_golden.py respectively.
  localparam logic [31:0] M2XFP4_U_EXPECTED = 32'h41EF_0000;  // 29.875f (M2XFP4)
  localparam logic [31:0] MXFP4_V_EXPECTED  = 32'h4180_0000;  // 16.0f   (MXFP4)
  localparam logic [31:0] MXFP8_W_EXPECTED  = 32'h4100_0000;  //  8.0f   (MXFP8 E4M3)

  localparam logic [31:0] INSTR_MXFUSED_M2U = encode_r4(
    MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_M2XFP4,
    REG_M2U_RESULT, REG_M2U_A_BASE, REG_M2U_B_BASE, REG_M2_RS3
  );
  localparam logic [31:0] INSTR_MXFUSED_M2V = encode_r4(
    MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP4,
    // A=B=x13 (same reg pair); rs3 shares U's word - the fp4 engine ignores
    // rs3[63:48], so U's metadata bits are invisible to it. That is the check.
    REG_M2V_RESULT, REG_M2V_AB_BASE, REG_M2V_AB_BASE, REG_M2_RS3
  );
  localparam logic [31:0] INSTR_MXFUSED_M2W = encode_r4(
    MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP8,
    // A=B=x22; rs3 shares U's word - the fp8 engine reads only rs3[48] (=0 ->
    // E4M3) from the range U uses for metadata.
    REG_M2W_RESULT, REG_M2W_AB_BASE, REG_M2W_AB_BASE, REG_M2_RS3
  );

  //----------------------------------------------------------------------------
  // Test 5: MXDOTP/MXFINAL mailbox robustness + a 2nd numeric residue case.
  //
  // Test 2 proves ONE MXDOTP->MXFINAL pair with the two instructions adjacent
  // (only integer LUI/ADDI loads between them). What no test proved until now:
  // that the single-entry mailbox carrying p1/p2 from MXDOTP to MXFINAL
  // survives an unrelated *MX* instruction landing between them, and that all
  // three retire in program order through the order queue with the DOTP
  // (no-writeback) and FINAL slots interleaved with a FUSED slot - a mix
  // Tests 3/4 (all FUSED-slot) never exercise. Sequence:
  //     MXDOTP(res2)  -> fills the mailbox with p1'/p2' (writes no register)
  //     MXFUSED(fp4)  -> UNRELATED plain MXFP4; runs on the fp4 fused engine,
  //                      which never touches the mailbox - the check is that
  //                      it cannot disturb the staged p1'/p2'
  //     MXFINAL(res2) -> drains the mailbox; must still see p1'/p2' intact
  // The residue operands are deliberately DIFFERENT from Test 2 (B=2.0 not
  // 1.0, a real Sa>Sar residue slide of delta=1, and a nonzero accumulator),
  // so this doubles as a second, independent numeric residue case.
  //
  // Expected values are GOLDEN-DERIVED, not hand-computed:
  //   python3 verification/mxdotp_golden.py --emit-system-consts
  // prints MXFP4_RESIDUAL2_EXPECTED (and reproduces Test 2's
  // MXFP4_RESIDUAL_EXPECTED as a cross-check). T5_FUSED_EXPECTED is a plain
  // MXFP4 A2.B2 at unit scale = 32.0.
  //
  // Destinations REUSE Test 1's x9 (fused) and Test 2's x21 (final): both are
  // written once earlier in the program, so Test 5's own writes are captured
  // by ARMED writeback latches in tb_mxdotp_core.sv (armed once Test 4's last
  // writeback retires), NOT the first-write-wins latches the earlier tests
  // use - see that file's Test 5 section. This is why no pristine register is
  // needed here (none remain free by this point in the program).
  //----------------------------------------------------------------------------
  localparam logic [3:0]  MXFP4_TWO      = 4'h4;   // E2M1 encoding of 2.0 (sign=0,exp=10,mant=0)
  localparam logic [7:0]  E8M0_SCALE_TWO = 8'd128; // 2^1 = 2.0

  localparam logic [4:0] REG_T5A_BASE         = 5'd13; // x13/x14: A2
  localparam logic [4:0] REG_T5B_BASE         = 5'd15; // x15/x16: B2
  localparam logic [4:0] REG_T5AR_BASE        = 5'd17; // x17/x18: AR2 (residue)
  localparam logic [4:0] REG_T5_FUSED_RS3     = 5'd5;  // x5/x6: interleaved fused rs3 {scales=1,acc=0}
  localparam logic [4:0] REG_T5_SCALES        = 5'd29; // x29: MXFINAL scales {a,ar,b,rsvd}
  localparam logic [4:0] REG_T5_OLD_ACC       = 5'd30; // x30: MXFINAL old accumulator
  localparam logic [4:0] REG_T5_FUSED_RESULT  = 5'd9;  // x9 : interleaved fused rd (reused; armed latch)
  localparam logic [4:0] REG_T5_RFINAL_RESULT = 5'd21; // x21: MXFINAL(res2) rd (reused; armed latch)

  localparam logic [63:0] T5A_VAL  = {16{MXFP4_ONE}};   // 16x 1.0 -> 0x2222_2222_2222_2222
  localparam logic [63:0] T5B_VAL  = {16{MXFP4_TWO}};   // 16x 2.0 -> 0x4444_4444_4444_4444
  localparam logic [63:0] T5AR_VAL = {16{MXFP4_HALF}};  // 16x 0.5 -> 0x1111_1111_1111_1111
  // interleaved fused rs3: {hi = {reserved,b_scale=1,a_scale=1}, lo = old_acc=0}
  localparam logic [63:0] T5_FUSED_RS3_VAL = {F_SCALES_HI_VAL, 32'h0000_0000};
  // MXFINAL scales: a_scale=2^1, ar_scale=2^0, b_scale=2^0 -> delta = Sa-Sar = 1
  localparam logic [31:0] T5_RSCALES_VAL  = {E8M0_SCALE_TWO, E8M0_SCALE_ONE, E8M0_SCALE_ONE, 8'd0};
  localparam logic [31:0] T5_OLD_ACC_VAL  = 32'h4080_0000;  // 4.0f

  // Golden-derived (verification/mxdotp_golden.py --emit-system-consts):
  localparam logic [31:0] MXFP4_RESIDUAL2_EXPECTED = 32'h42A8_0000;  // 84.0f (residue #2)
  localparam logic [31:0] T5_FUSED_EXPECTED        = 32'h4200_0000;  // 32.0f (plain MXFP4 A2.B2, unit scale)

  localparam logic [31:0] INSTR_MXDOTP_RES2 = encode_r4(
    MX_OPCODE, MX_FUNCT3_DOTP, MX_FMT_MXFP4_RESIDUAL,
    5'd0 /*rd unused - no writeback*/, REG_T5A_BASE, REG_T5B_BASE, REG_T5AR_BASE
  );
  // The UNRELATED instruction interleaved between DOTP and FINAL: plain MXFP4
  // of A2.B2 at unit scale (rs3 = {scales=1, acc=0}) -> 32.0.
  localparam logic [31:0] INSTR_MXFUSED_T5 = encode_r4(
    MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP4,
    REG_T5_FUSED_RESULT, REG_T5A_BASE, REG_T5B_BASE, REG_T5_FUSED_RS3
  );
  localparam logic [31:0] INSTR_MXFINAL_RES2 = encode_r4(
    MX_OPCODE, MX_FUNCT3_FINAL, MX_FMT_MXFP4_RESIDUAL,
    REG_T5_RFINAL_RESULT, REG_T5_SCALES, REG_T5_OLD_ACC, 5'd0 /*rs3 unused*/
  );

  //----------------------------------------------------------------------------
  // Test 6: back-to-back MXDOTP/MXFINAL pairs (DOTP, FINAL, DOTP, FINAL, ...).
  //
  // Tests 2 and 5 only ever run ONE residue pair at a time, so the DOTP result
  // always reaches the XIF while the DOTP slot is already at the order-queue
  // head. Back-to-back pairs break that: the 2nd DOTP's result can leave the
  // DOTP engine while the 1st FINAL still holds the head. This test checks
  // that every pair still completes, in program order, with the right value.
  // (Found 21 Oct 2026 by the make-stream measurement: at that point the 2nd
  // DOTP's XIF result was lost and the core hung waiting for it in WB.)
  //
  // Operands REUSE Test 5's registers unchanged (x13-x18 A2/B2/AR2, x29
  // scales, x30 old_acc = 4.0) and the identical instruction words, so every
  // FINAL must produce MXFP4_RESIDUAL2_EXPECTED (84.0, golden-derived - see
  // Test 5). Checked on the RESULT channel by tb_mxdotp_core.sv's Test 6
  // monitor (DOTP: we=0; FINAL: we=1, rd=x21, data=84.0), not by WB latches.
  //----------------------------------------------------------------------------
  localparam int unsigned T6_NUM_PAIRS = 3;

  localparam logic [31:0] INSTR_JAL_SELF = encode_j(OPCODE_JAL, 5'd0, 21'd0); // infinite self-loop
  localparam logic [31:0] INSTR_NOP      = encode_i(OPCODE_OPIMM, 3'b000, 5'd0, 5'd0, 12'd0);

  logic [31:0] rom [0:NUM_WORDS-1];

`ifdef MX_STREAM_TEST
  //----------------------------------------------------------------------------
  // Directed stream program (make stream only - MX_STREAM_TEST). Measures the
  // sustained rate of back-to-back MX instructions; it replaces Tests 1-5, so
  // the scoreboard is not used in this build (see tb_mxdotp_core.sv) and the
  // output is the [XIFMON] log.
  //
  // Streams, in program order (S5 runs before S4), each followed by
  // STREAM_GAP NOPs:
  //   S1  16 x mxfused MXFP4         rs1=x2  rs2=x4  rs3=x6   rd = x20..x27 rotating
  //   S2  16 x mxfused MXFP8 E4M3    rs1=x8  rs2=x8  rs3=x10  rd = x20..x27 rotating
  //   S3  16 x mxfused M2XFP4        rs1=x12 rs2=x4  rs3=x14  rd = x20..x27 rotating
  //   S5  16 x mxfused MXFP4 chained: rd=x28 is the next instruction's
  //       accumulator (rs3 = {x29 scales, x28 acc})
  //   S4  16 x (mxresdot rs1=x2 rs2=x4 rs3=x16, rd=x0;
  //             mxfinal  rs1=x18 rs2=x19,        rd = x20..x27 rotating)
  //       (Before the 21 Oct mxdotp_xif.sv fix this stream hung at its second
  //       pair, which is why it runs after S5.)
  //   S6  mailbox-depth boundary: 5 x mxresdot back to back, then 5 x mxfinal
  //       (same operands as S4). The 5th mxresdot finds the mailbox full and
  //       can only retire because the next instruction is an mxfinal - see the
  //       MAILBOX_DEPTH usage rule in mxdotp_xif.sv. 6 would deadlock.
  // Register audit: sources are x2-x19 and x28/x29, loaded once up front;
  // x20-x27 are written and never read, so S1-S4 have no data dependencies
  // between instructions. Only S5 is dependent, on purpose.
  //
  // Expected results (golden models, bit-level model == exact reference):
  //   S1 0x41800000 (16.0)   S2 0x41000000 (8.0)   S3 0x41EF0000 (29.875)
  //   S4 and S6 mxfinal 0x41C00000 (24.0, mxresdot p1=64 p2=32)
  //   S5 16.0, 32.0, ..., 256.0 (step k: 16*k)
  //----------------------------------------------------------------------------
  localparam int unsigned STREAM_LEN = 16;
  localparam int unsigned STREAM_GAP = 12;
  localparam int unsigned STREAM_S6_DEPTH = 5;  // MAILBOX_DEPTH + 1
  localparam int unsigned STREAM_NUM_LOADS = 20;

  localparam logic [4:0]  STREAM_LOAD_REG [0:STREAM_NUM_LOADS-1] = '{
    5'd2,  5'd3,  5'd4,  5'd5,  5'd6,  5'd7,  5'd8,  5'd9,  5'd10, 5'd11,
    5'd12, 5'd13, 5'd14, 5'd15, 5'd16, 5'd17, 5'd18, 5'd19, 5'd28, 5'd29
  };
  localparam logic [31:0] STREAM_LOAD_VAL [0:STREAM_NUM_LOADS-1] = '{
    32'h2222_2222, 32'h2222_2222,   // x2/x3   MXFP4 A  = 16x 1.0
    32'h2222_2222, 32'h2222_2222,   // x4/x5   MXFP4 B  = 16x 1.0
    32'h0000_0000, 32'h0000_7F7F,   // x6/x7   rs3: acc 0.0 / {b=127,a=127}
    32'h3838_3838, 32'h3838_3838,   // x8/x9   E4M3 A=B = 8x 1.0
    32'h0000_0000, 32'h0000_7F7F,   // x10/x11 rs3: acc 0.0 / scales, bit48=0 (E4M3)
    32'h2222_2722, 32'h2222_2222,   // x12/x13 M2XFP4 A (Test 4's U activations)
    32'h0000_0000, 32'h013E_7F7F,   // x14/x15 rs3: acc 0.0 / sg_em={2,1} elem_em={3,3} scales
    32'h1111_1111, 32'h1111_1111,   // x16/x17 residue AR = 16x 0.5
    32'h7F7F_7F00,                  // x18     mxfinal scales {a,ar,b,rsvd} = 127/127/127
    32'h0000_0000,                  // x19     mxfinal old acc 0.0
    32'h0000_0000, 32'h0000_7F7F    // x28/x29 chain rs3: acc 0.0 / scales
  };

  task automatic stream_program();
    int unsigned p;
    logic [31:0] lui_w, addi_w;
    p = 0;
    for (int unsigned k = 0; k < STREAM_NUM_LOADS; k++) begin
      encode_li32(STREAM_LOAD_REG[k], STREAM_LOAD_VAL[k], lui_w, addi_w);
      rom[p] = lui_w;  p = p + 1;
      rom[p] = addi_w; p = p + 1;
    end
    p = p + STREAM_GAP;  // rom[] is pre-filled with NOPs
    // S1: MXFP4
    for (int unsigned k = 0; k < STREAM_LEN; k++) begin
      rom[p] = encode_r4(MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP4, 5'(20 + k % 8), 5'd2, 5'd4, 5'd6);
      p = p + 1;
    end
    p = p + STREAM_GAP;
    // S2: MXFP8 E4M3
    for (int unsigned k = 0; k < STREAM_LEN; k++) begin
      rom[p] = encode_r4(MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP8, 5'(20 + k % 8), 5'd8, 5'd8, 5'd10);
      p = p + 1;
    end
    p = p + STREAM_GAP;
    // S3: M2XFP4
    for (int unsigned k = 0; k < STREAM_LEN; k++) begin
      rom[p] = encode_r4(MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_M2XFP4, 5'(20 + k % 8), 5'd12, 5'd4, 5'd14);
      p = p + 1;
    end
    p = p + STREAM_GAP;
    // S5: MXFP4 accumulator chain (rd = next rs3 low word)
    for (int unsigned k = 0; k < STREAM_LEN; k++) begin
      rom[p] = encode_r4(MX_OPCODE, MX_FUNCT3_FUSED, MX_FMT_MXFP4, 5'd28, 5'd2, 5'd4, 5'd28);
      p = p + 1;
    end
    p = p + STREAM_GAP;
    // S4: mxresdot / mxfinal pairs
    for (int unsigned k = 0; k < STREAM_LEN; k++) begin
      rom[p] = encode_r4(MX_OPCODE, MX_FUNCT3_DOTP,  MX_FMT_MXFP4_RESIDUAL, 5'd0, 5'd2, 5'd4, 5'd16);
      p = p + 1;
      rom[p] = encode_r4(MX_OPCODE, MX_FUNCT3_FINAL, MX_FMT_MXFP4_RESIDUAL, 5'(20 + k % 8), 5'd18, 5'd19, 5'd0);
      p = p + 1;
    end
    p = p + STREAM_GAP;
    // S6: 5 x mxresdot, then 5 x mxfinal (mailbox-depth boundary)
    for (int unsigned k = 0; k < STREAM_S6_DEPTH; k++) begin
      rom[p] = encode_r4(MX_OPCODE, MX_FUNCT3_DOTP,  MX_FMT_MXFP4_RESIDUAL, 5'd0, 5'd2, 5'd4, 5'd16);
      p = p + 1;
    end
    for (int unsigned k = 0; k < STREAM_S6_DEPTH; k++) begin
      rom[p] = encode_r4(MX_OPCODE, MX_FUNCT3_FINAL, MX_FMT_MXFP4_RESIDUAL, 5'(20 + k % 8), 5'd18, 5'd19, 5'd0);
      p = p + 1;
    end
    p = p + STREAM_GAP;
    rom[p] = INSTR_JAL_SELF;
    assert (p < NUM_WORDS) else $fatal(1, "stream program overflows rom[] (%0d words)", p + 1);
  endtask
`endif

  initial begin
    int i;
    logic [31:0] lui_a_lo, addi_a_lo, lui_a_hi, addi_a_hi;
    logic [31:0] lui_b_lo, addi_b_lo, lui_b_hi, addi_b_hi;
    logic [31:0] lui_frs3_lo, addi_frs3_lo, lui_frs3_hi, addi_frs3_hi;
    logic [31:0] lui_qa_lo, addi_qa_lo, lui_qa_hi, addi_qa_hi;
    logic [31:0] lui_qb_lo, addi_qb_lo, lui_qb_hi, addi_qb_hi;
    logic [31:0] lui_rrs3_lo, addi_rrs3_lo, lui_rrs3_hi, addi_rrs3_hi;
    logic [31:0] lui_dr_lo, addi_dr_lo, lui_dr_hi, addi_dr_hi;
    logic [31:0] lui_ra_lo, addi_ra_lo, lui_ra_hi, addi_ra_hi;
    logic [31:0] lui_rb_lo, addi_rb_lo, lui_rb_hi, addi_rb_hi;
    logic [31:0] lui_rar_lo, addi_rar_lo, lui_rar_hi, addi_rar_hi;
    logic [31:0] lui_rscales, addi_rscales, lui_racc, addi_racc;
    // Test 3 (MXFP8 + overlap) operand loads
    logic [31:0] lui_f8sa_lo, addi_f8sa_lo, lui_f8sa_hi, addi_f8sa_hi;
    logic [31:0] lui_f8sb_lo, addi_f8sb_lo, lui_f8sb_hi, addi_f8sb_hi;
    logic [31:0] lui_f8e4_lo, addi_f8e4_lo, lui_f8e4_hi, addi_f8e4_hi;
    logic [31:0] lui_f4m_lo,  addi_f4m_lo,  lui_f4m_hi,  addi_f4m_hi;
    logic [31:0] lui_f8t_lo,  addi_f8t_lo,  lui_f8t_hi,  addi_f8t_hi;
    logic [31:0] lui_f8e5_lo, addi_f8e5_lo, lui_f8e5_hi, addi_f8e5_hi;
    // Test 4 (M2XFP4 + three-engine overlap) operand loads
    logic [31:0] lui_m2ua_lo, addi_m2ua_lo, lui_m2ua_hi, addi_m2ua_hi;
    logic [31:0] lui_m2ub_lo, addi_m2ub_lo, lui_m2ub_hi, addi_m2ub_hi;
    logic [31:0] lui_m2r3_lo, addi_m2r3_lo, lui_m2r3_hi, addi_m2r3_hi;
    logic [31:0] lui_m2v_lo,  addi_m2v_lo,  lui_m2v_hi,  addi_m2v_hi;
    logic [31:0] lui_m2w_lo,  addi_m2w_lo,  lui_m2w_hi,  addi_m2w_hi;
    // Test 5 (residue mailbox robustness) operand loads
    logic [31:0] lui_t5a_lo,  addi_t5a_lo,  lui_t5a_hi,  addi_t5a_hi;
    logic [31:0] lui_t5b_lo,  addi_t5b_lo,  lui_t5b_hi,  addi_t5b_hi;
    logic [31:0] lui_t5ar_lo, addi_t5ar_lo, lui_t5ar_hi, addi_t5ar_hi;
    logic [31:0] lui_t5fr3_lo,addi_t5fr3_lo,lui_t5fr3_hi,addi_t5fr3_hi;
    logic [31:0] lui_t5sc,    addi_t5sc,    lui_t5acc,   addi_t5acc;

    for (i = 0; i < NUM_WORDS; i++) rom[i] = INSTR_NOP;

    encode_li32(REG_FA_BASE,        A_VAL[31:0],  lui_a_lo,  addi_a_lo);
    encode_li32(REG_FA_BASE + 5'd1, A_VAL[63:32], lui_a_hi,  addi_a_hi);
    encode_li32(REG_FB_BASE,        B_VAL[31:0],  lui_b_lo,  addi_b_lo);
    encode_li32(REG_FB_BASE + 5'd1, B_VAL[63:32], lui_b_hi,  addi_b_hi);
    encode_li32(REG_FRS3_BASE,        FRS3_VAL[31:0],  lui_frs3_lo, addi_frs3_lo);
    encode_li32(REG_FRS3_BASE + 5'd1, FRS3_VAL[63:32], lui_frs3_hi, addi_frs3_hi);

    encode_li32(REG_QA_BASE,        QA_VAL[31:0],  lui_qa_lo, addi_qa_lo);
    encode_li32(REG_QA_BASE + 5'd1, QA_VAL[63:32], lui_qa_hi, addi_qa_hi);
    encode_li32(REG_QB_BASE,        QB_VAL[31:0],  lui_qb_lo, addi_qb_lo);
    encode_li32(REG_QB_BASE + 5'd1, QB_VAL[63:32], lui_qb_hi, addi_qb_hi);

    encode_li32(REG_RRS3_BASE,        RRS3_VAL[31:0],  lui_rrs3_lo, addi_rrs3_lo);
    encode_li32(REG_RRS3_BASE + 5'd1, RRS3_VAL[63:32], lui_rrs3_hi, addi_rrs3_hi);

    encode_li32(REG_DR_BASE,        DUALREAD_LO_VAL, lui_dr_lo, addi_dr_lo);
    encode_li32(REG_DR_BASE + 5'd1, DUALREAD_HI_VAL, lui_dr_hi, addi_dr_hi);

    encode_li32(REG_RA_BASE,         RA_VAL[31:0],   lui_ra_lo,  addi_ra_lo);
    encode_li32(REG_RA_BASE + 5'd1,  RA_VAL[63:32],  lui_ra_hi,  addi_ra_hi);
    encode_li32(REG_RB_BASE,         RB_VAL[31:0],   lui_rb_lo,  addi_rb_lo);
    encode_li32(REG_RB_BASE + 5'd1,  RB_VAL[63:32],  lui_rb_hi,  addi_rb_hi);
    encode_li32(REG_RAR_BASE,        RAR_VAL[31:0],  lui_rar_lo, addi_rar_lo);
    encode_li32(REG_RAR_BASE + 5'd1, RAR_VAL[63:32], lui_rar_hi, addi_rar_hi);
    encode_li32(REG_RSCALES,  RSCALES_VAL,  lui_rscales, addi_rscales);
    encode_li32(REG_ROLD_ACC, ROLD_ACC_VAL, lui_racc,    addi_racc);

    // Test 3 operands (loaded fresh - earlier tests have consumed their own).
    encode_li32(REG_F8S_A_BASE,        F8S_A_VAL[31:0],     lui_f8sa_lo, addi_f8sa_lo);
    encode_li32(REG_F8S_A_BASE + 5'd1, F8S_A_VAL[63:32],    lui_f8sa_hi, addi_f8sa_hi);
    encode_li32(REG_F8S_B_BASE,        F8S_B_VAL[31:0],     lui_f8sb_lo, addi_f8sb_lo);
    encode_li32(REG_F8S_B_BASE + 5'd1, F8S_B_VAL[63:32],    lui_f8sb_hi, addi_f8sb_hi);
    encode_li32(REG_F8_E4_RS3,         F8_E4_RS3_VAL[31:0], lui_f8e4_lo, addi_f8e4_lo);
    encode_li32(REG_F8_E4_RS3 + 5'd1,  F8_E4_RS3_VAL[63:32],lui_f8e4_hi, addi_f8e4_hi);
    encode_li32(REG_F4M_AB_BASE,        F4M_AB_VAL[31:0],   lui_f4m_lo,  addi_f4m_lo);
    encode_li32(REG_F4M_AB_BASE + 5'd1, F4M_AB_VAL[63:32],  lui_f4m_hi,  addi_f4m_hi);
    encode_li32(REG_F8T_AB_BASE,        F8T_AB_VAL[31:0],   lui_f8t_lo,  addi_f8t_lo);
    encode_li32(REG_F8T_AB_BASE + 5'd1, F8T_AB_VAL[63:32],  lui_f8t_hi,  addi_f8t_hi);
    encode_li32(REG_F8_E5_RS3,         F8_E5_RS3_VAL[31:0], lui_f8e5_lo, addi_f8e5_lo);
    encode_li32(REG_F8_E5_RS3 + 5'd1,  F8_E5_RS3_VAL[63:32],lui_f8e5_hi, addi_f8e5_hi);

    // Test 4 operands (loaded fresh - Test 3 has consumed its own).
    encode_li32(REG_M2U_A_BASE,         M2U_A_VAL[31:0],   lui_m2ua_lo, addi_m2ua_lo);
    encode_li32(REG_M2U_A_BASE + 5'd1,  M2U_A_VAL[63:32],  lui_m2ua_hi, addi_m2ua_hi);
    encode_li32(REG_M2U_B_BASE,         M2U_B_VAL[31:0],   lui_m2ub_lo, addi_m2ub_lo);
    encode_li32(REG_M2U_B_BASE + 5'd1,  M2U_B_VAL[63:32],  lui_m2ub_hi, addi_m2ub_hi);
    encode_li32(REG_M2_RS3,             M2_RS3_VAL[31:0],  lui_m2r3_lo, addi_m2r3_lo);
    encode_li32(REG_M2_RS3 + 5'd1,      M2_RS3_VAL[63:32], lui_m2r3_hi, addi_m2r3_hi);
    encode_li32(REG_M2V_AB_BASE,        M2V_AB_VAL[31:0],  lui_m2v_lo,  addi_m2v_lo);
    encode_li32(REG_M2V_AB_BASE + 5'd1, M2V_AB_VAL[63:32], lui_m2v_hi,  addi_m2v_hi);
    encode_li32(REG_M2W_AB_BASE,        M2W_AB_VAL[31:0],  lui_m2w_lo,  addi_m2w_lo);
    encode_li32(REG_M2W_AB_BASE + 5'd1, M2W_AB_VAL[63:32], lui_m2w_hi,  addi_m2w_hi);

    // Test 5 operands (loaded fresh - Test 4 overwrote x5/x6/x13-x18/x29/x30).
    encode_li32(REG_T5A_BASE,         T5A_VAL[31:0],   lui_t5a_lo,   addi_t5a_lo);
    encode_li32(REG_T5A_BASE + 5'd1,  T5A_VAL[63:32],  lui_t5a_hi,   addi_t5a_hi);
    encode_li32(REG_T5B_BASE,         T5B_VAL[31:0],   lui_t5b_lo,   addi_t5b_lo);
    encode_li32(REG_T5B_BASE + 5'd1,  T5B_VAL[63:32],  lui_t5b_hi,   addi_t5b_hi);
    encode_li32(REG_T5AR_BASE,        T5AR_VAL[31:0],  lui_t5ar_lo,  addi_t5ar_lo);
    encode_li32(REG_T5AR_BASE + 5'd1, T5AR_VAL[63:32], lui_t5ar_hi,  addi_t5ar_hi);
    encode_li32(REG_T5_FUSED_RS3,        T5_FUSED_RS3_VAL[31:0],  lui_t5fr3_lo, addi_t5fr3_lo);
    encode_li32(REG_T5_FUSED_RS3 + 5'd1, T5_FUSED_RS3_VAL[63:32], lui_t5fr3_hi, addi_t5fr3_hi);
    encode_li32(REG_T5_SCALES,  T5_RSCALES_VAL, lui_t5sc,  addi_t5sc);
    encode_li32(REG_T5_OLD_ACC, T5_OLD_ACC_VAL, lui_t5acc, addi_t5acc);

`ifdef MX_STREAM_TEST
    stream_program();
`else
    // --- Test 1: MXFUSED x3 back-to-back (P, Q, R) ---
    // ALL operands for P, Q, and R are loaded FIRST, before any of the three
    // FUSED instructions issue - this is deliberate: once P/Q/R start
    // issuing, nothing else is interspersed between them, so they reach
    // the core back-to-back with minimal gap, giving P's, Q's, and R's own
    // journeys through mxdotp_fused_engine.sv's pipeline every opportunity
    // to genuinely overlap rather than being serialized by unrelated
    // instructions in between.
    rom[0]  = lui_a_lo;
    rom[1]  = addi_a_lo;      // x1 <- P/R's A[31:0]
    rom[2]  = lui_a_hi;
    rom[3]  = addi_a_hi;      // x2 <- P/R's A[63:32]
    rom[4]  = lui_b_lo;
    rom[5]  = addi_b_lo;      // x3 <- P's B[31:0]
    rom[6]  = lui_b_hi;
    rom[7]  = addi_b_hi;      // x4 <- P's B[63:32]
    rom[8]  = lui_frs3_lo;
    rom[9]  = addi_frs3_lo;   // x5 <- P/Q's old_acc (0.0)
    rom[10] = lui_frs3_hi;
    rom[11] = addi_frs3_hi;   // x6 <- P/Q's {reserved,b_scale,a_scale}
    rom[12] = lui_qa_lo;
    rom[13] = addi_qa_lo;     // x22 <- Q's A[31:0]
    rom[14] = lui_qa_hi;
    rom[15] = addi_qa_hi;     // x23 <- Q's A[63:32]
    rom[16] = lui_qb_lo;
    rom[17] = addi_qb_lo;     // x24 <- Q/R's B[31:0]
    rom[18] = lui_qb_hi;
    rom[19] = addi_qb_hi;     // x25 <- Q/R's B[63:32]
    rom[20] = lui_rrs3_lo;
    rom[21] = addi_rrs3_lo;   // x29 <- R's old_acc (100.0)
    rom[22] = lui_rrs3_hi;
    rom[23] = addi_rrs3_hi;   // x30 <- R's {reserved,b_scale,a_scale}
    rom[24] = INSTR_MXFUSED;    // P: rd=x9,  expect 16.0
    rom[25] = INSTR_MXFUSED_Q;  // Q: rd=x28, expect  4.0 - issued immediately after P, no gap
    rom[26] = INSTR_MXFUSED_R;  // R: rd=x31, expect 108.0 - issued immediately after Q, no gap

    // --- Dual-read validation: MX_FUNCT3_DUALREAD_TEST ---
    // x10 (lo) is written well before the test instruction - port 0 just reads the regfile
    // normally here, nothing new to prove. x11 (hi, = x10+1) is written with ZERO NOPs
    // before MXDUALREAD_TEST on purpose: this forces x11's producer (addi_dr_hi) to still
    // be in EX exactly when MXDUALREAD_TEST is in ID, exercising the EX->ID forwarding path
    // for the rs1+1 companion port (operand_a_hi_fw_mux_sel == SEL_FW_EX). If the companion-
    // port address generation, read-enable gating, or forwarding is wrong, x12 will end up
    // with something other than DUALREAD_HI_VAL instead.
    rom[27] = lui_dr_lo;
    rom[28] = addi_dr_lo;  // x10 <- 0xAAAAAAAA (lo half; not the value under test)
    rom[29] = lui_dr_hi;
    rom[30] = addi_dr_hi;  // x11 <- 0xBBBBBBBB; MXDUALREAD_TEST immediately follows, no NOP
    rom[31] = INSTR_MXDUALREAD_TEST;

    // --- Test 2: MXDOTP/MXFINAL, MX_FMT_MXFP4_RESIDUAL (k=16, with residue) ---
    rom[32] = lui_ra_lo;
    rom[33] = addi_ra_lo;   // x13 <- A[31:0]
    rom[34] = lui_ra_hi;
    rom[35] = addi_ra_hi;   // x14 <- A[63:32]
    rom[36] = lui_rb_lo;
    rom[37] = addi_rb_lo;   // x15 <- B[31:0]
    rom[38] = lui_rb_hi;
    rom[39] = addi_rb_hi;   // x16 <- B[63:32]
    rom[40] = lui_rar_lo;
    rom[41] = addi_rar_lo;  // x17 <- AR[31:0]
    rom[42] = lui_rar_hi;
    rom[43] = addi_rar_hi;  // x18 <- AR[63:32]
    rom[44] = INSTR_MXDOTP_RESIDUAL;
    rom[45] = lui_rscales;
    rom[46] = addi_rscales; // x19 <- scales
    rom[47] = lui_racc;
    rom[48] = addi_racc;    // x20 <- old accumulator (0.0)
    rom[49] = INSTR_MXFINAL_RESIDUAL;

    // --- Test 3: MXFP8 (E4M3 + E5M2) + cross-engine overlap (S, M, T) ---
    // All Test-3 operands loaded FIRST, then the three MXFUSED instructions
    // issue back-to-back with nothing between them, so S (fp8), M (fp4) and
    // T (fp8) genuinely overlap across the two engines.
    rom[50] = lui_f8sa_lo;  rom[51] = addi_f8sa_lo;   // x1  <- S's A[31:0]
    rom[52] = lui_f8sa_hi;  rom[53] = addi_f8sa_hi;   // x2  <- S's A[63:32]
    rom[54] = lui_f8sb_lo;  rom[55] = addi_f8sb_lo;   // x3  <- S's B[31:0]
    rom[56] = lui_f8sb_hi;  rom[57] = addi_f8sb_hi;   // x4  <- S's B[63:32]
    rom[58] = lui_f8e4_lo;  rom[59] = addi_f8e4_lo;   // x5  <- E4M3 rs3[31:0] (old_acc)
    rom[60] = lui_f8e4_hi;  rom[61] = addi_f8e4_hi;   // x6  <- E4M3 rs3[63:32] (scales, bit48=0)
    rom[62] = lui_f4m_lo;   rom[63] = addi_f4m_lo;    // x13 <- M's A=B[31:0]
    rom[64] = lui_f4m_hi;   rom[65] = addi_f4m_hi;    // x14 <- M's A=B[63:32]
    rom[66] = lui_f8t_lo;   rom[67] = addi_f8t_lo;    // x22 <- T's A=B[31:0]
    rom[68] = lui_f8t_hi;   rom[69] = addi_f8t_hi;    // x23 <- T's A=B[63:32]
    rom[70] = lui_f8e5_lo;  rom[71] = addi_f8e5_lo;   // x24 <- E5M2 rs3[31:0] (old_acc)
    rom[72] = lui_f8e5_hi;  rom[73] = addi_f8e5_hi;   // x25 <- E5M2 rs3[63:32] (scales, bit48=1)
    rom[74] = INSTR_MXFUSED_F8S;   // S: MXFP8 E4M3, rd=x7,  expect 10.5
    rom[75] = INSTR_MXFUSED_F4M;   // M: MXFP4,      rd=x8,  expect 16.0 - right after S, no gap
    rom[76] = INSTR_MXFUSED_F8T;   // T: MXFP8 E5M2, rd=x26, expect  8.0 - right after M, no gap

    // --- Test 4: M2XFP4 + three-engine overlap (U, V, W) ---
    // Same discipline as Test 3: ALL Test-4 operands loaded FIRST, then the
    // three MXFUSED instructions issue back-to-back with nothing between them,
    // so U (m2), V (fp4) and W (fp8) are genuinely in flight across all three
    // engines simultaneously.
    rom[77] = lui_m2ua_lo;  rom[78] = addi_m2ua_lo;   // x1  <- U's A[31:0]
    rom[79] = lui_m2ua_hi;  rom[80] = addi_m2ua_hi;   // x2  <- U's A[63:32]
    rom[81] = lui_m2ub_lo;  rom[82] = addi_m2ub_lo;   // x3  <- U's B[31:0]
    rom[83] = lui_m2ub_hi;  rom[84] = addi_m2ub_hi;   // x4  <- U's B[63:32]
    rom[85] = lui_m2r3_lo;  rom[86] = addi_m2r3_lo;   // x5  <- shared rs3[31:0] (old_acc = 0.0)
    rom[87] = lui_m2r3_hi;  rom[88] = addi_m2r3_hi;   // x6  <- shared rs3[63:32] (meta+scales)
    rom[89] = lui_m2v_lo;   rom[90] = addi_m2v_lo;    // x13 <- V's A=B[31:0]
    rom[91] = lui_m2v_hi;   rom[92] = addi_m2v_hi;    // x14 <- V's A=B[63:32]
    rom[93] = lui_m2w_lo;   rom[94] = addi_m2w_lo;    // x22 <- W's A=B[31:0]
    rom[95] = lui_m2w_hi;   rom[96] = addi_m2w_hi;    // x23 <- W's A=B[63:32]
    rom[97]  = INSTR_MXFUSED_M2U;  // U: M2XFP4, rd=x27, expect 29.875
    rom[98]  = INSTR_MXFUSED_M2V;  // V: MXFP4,  rd=x19, expect 16.0 - right after U, no gap
    rom[99]  = INSTR_MXFUSED_M2W;  // W: MXFP8,  rd=x20, expect  8.0 - right after V, no gap

    // --- Test 5: MXDOTP/MXFINAL mailbox robustness + 2nd numeric residue ---
    // Operands loaded fresh (Test 4 overwrote x5/x6/x13-x18/x29/x30).
    rom[100] = lui_t5a_lo;   rom[101] = addi_t5a_lo;    // x13 <- A2[31:0]
    rom[102] = lui_t5a_hi;   rom[103] = addi_t5a_hi;    // x14 <- A2[63:32]
    rom[104] = lui_t5b_lo;   rom[105] = addi_t5b_lo;    // x15 <- B2[31:0]
    rom[106] = lui_t5b_hi;   rom[107] = addi_t5b_hi;    // x16 <- B2[63:32]
    rom[108] = lui_t5ar_lo;  rom[109] = addi_t5ar_lo;   // x17 <- AR2[31:0]
    rom[110] = lui_t5ar_hi;  rom[111] = addi_t5ar_hi;   // x18 <- AR2[63:32]
    rom[112] = lui_t5fr3_lo; rom[113] = addi_t5fr3_lo;  // x5  <- fused rs3[31:0] (old_acc=0)
    rom[114] = lui_t5fr3_hi; rom[115] = addi_t5fr3_hi;  // x6  <- fused rs3[63:32] (scales=1)
    rom[116] = lui_t5sc;     rom[117] = addi_t5sc;      // x29 <- MXFINAL scales2
    rom[118] = lui_t5acc;    rom[119] = addi_t5acc;     // x30 <- MXFINAL old_acc (4.0)
    // The sequence under test - an UNRELATED MXFUSED sits between the DOTP and
    // the FINAL. The mailbox must carry p1'/p2' across it, and all three must
    // retire in program order (DOTP no-wb, then FUSED, then FINAL).
    rom[120] = INSTR_MXDOTP_RES2;   // res2 DOTP  -> mailbox (writes no register)
    rom[121] = INSTR_MXFUSED_T5;    // unrelated MXFP4 (rd=x9) -> must not disturb mailbox
    rom[122] = INSTR_MXFINAL_RES2;  // res2 FINAL (rd=x21) -> drains mailbox

    // --- Test 6: back-to-back MXDOTP/MXFINAL pairs, nothing in between ---
    rom[123] = INSTR_MXDOTP_RES2;   // pair 1
    rom[124] = INSTR_MXFINAL_RES2;
    rom[125] = INSTR_MXDOTP_RES2;   // pair 2 - its DOTP result can complete while pair 1's FINAL holds the head
    rom[126] = INSTR_MXFINAL_RES2;
    rom[127] = INSTR_MXDOTP_RES2;   // pair 3
    rom[128] = INSTR_MXFINAL_RES2;

    rom[129] = INSTR_JAL_SELF;

    // Add further instructions here, e.g.:
    //   rom[130] = encode_i(OPCODE_OPIMM, 3'b000, 5'd6, 5'd0, 12'd1);
`endif
  end

  //----------------------------------------------------------------------------
  // Minimal, reset-gated OBI-style fetch interface
  //----------------------------------------------------------------------------

  logic        req_q;
  logic [31:0] addr_q;

  // Never grant while in reset - see file header for why this matters.
  assign instr_gnt_o = rst_ni & instr_req_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_q  <= 1'b0;
      addr_q <= '0;
    end else begin
      req_q  <= instr_req_i & instr_gnt_o;
      addr_q <= instr_addr_i;
    end
  end

  assign instr_rvalid_o = req_q;
  assign instr_rdata_o  = rom[addr_q[$clog2(NUM_WORDS)+1:2]];
  assign instr_err_o    = 1'b0;

endmodule
