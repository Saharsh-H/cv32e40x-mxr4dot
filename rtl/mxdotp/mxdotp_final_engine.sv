//==============================================================================
// File    : mxdotp_final_engine.sv
// Project : MXDOTP XIF Coprocessor
//------------------------------------------------------------------------------
// Description:
//   Standalone MXFINAL arithmetic engine - the FINAL half of what used to be
//   one shared mxdotp_execute module. See mxdotp_xif.sv's "pipelined
//   coprocessor" milestone header (mxdotp_pkg.sv) for the full rationale.
//
//   rs1=scales ({a_scale[31:24],ar_scale[23:16],b_scale[15:8],reserved[7:0]}),
//   rs2=old FP32 accumulator - BOTH plain 32-bit reads, no dual-read for
//   either, in any format.
//
//   RESIDUE-STYLE FORMATS ONLY as of the fused-fast-path milestone (see
//   mxdotp_pkg.sv's MX_SLOT_FUSED milestone header): plain (non-residue)
//   MXFP4/MXFP8 now go exclusively through mxdotp_fused_engine.sv and never
//   reach this engine at all. Because every instruction reaching this
//   engine is therefore guaranteed - by ISA convention, not a runtime check
//   - to be a residue-style format, the format mask this engine used to
//   apply is gone: p2/residue's contribution is now included
//   UNCONDITIONALLY, always. There is no mx_format input any more; nothing
//   left in this engine's own logic is format-dependent.
//
//   p1_i/p2_i are the "mailbox" snapshot - MXDOTP's raw, unscaled dot-product
//   sums. This engine captures them into its own private registers at
//   start_i, on the exact same cycle (and via the exact same mechanism) it
//   captures rs1_i/rs2_i - there is nothing special-cased about the
//   snapshot; it is an ordinary input capture like any other operand. The
//   caller (mxdotp_xif.sv) is responsible for only asserting start_i once
//   the mailbox actually holds valid data, and for freeing the mailbox the
//   same cycle - this engine has no visibility into "is the mailbox valid",
//   it just captures whatever is on p1_i/p2_i the cycle it is told to start.
//
//   MILESTONE (current): back-end pipelining for timing closure - see
//   mxdotp_fused_engine.sv's matching milestone header for the full
//   rationale (Vivado OOC synthesis measured this engine's own critical
//   path at ~28.55ns against a 10ns target, the identical root cause: one
//   unbroken combinational cloud from p1_q/p2_q/rs1_q/rs2_q all the way to
//   result_data_q, because acc_to_fp32 was a single monolithic function
//   with nowhere for a caller to put a register). This is "Option 2"
//   (balanced) applied here exactly as in mxdotp_fused_engine.sv: what used
//   to be one combinational stage (LATENCY_CYCLES-gated, but really just
//   one cycle's worth of logic regardless of the counter value) is now
//   THREE real stages:
//   - BACK1A: decode scales, calculate shift amounts, and perform variable shifts (place_in_acc).
//       Registers the three 74-bit shifted operands and their stickies. (The new cut).
//   - BACK1B: the 74-bit wide adder tree (summing the shifted operands).
//       Registers sum_q (the X|Y cut).
//   - BACK2: mxdotp_pkg.sv's acc_find_lead (leading-one scan) on sum_q ->
//       registers lead_q (the Y|Z cut - the single highest-leverage cut
//       identified from Vivado's timing report).
//     - BACK3: mxdotp_pkg.sv's acc_finalize (mantissa extract + sticky +
//       round + clamp) on lead_q -> result_data_q.
//   Each stage is a REAL single cycle now, not an artificial wait - the old
//   LATENCY_CYCLES parameter is gone, replaced by the genuine 3-stage
//   depth. Net latency: was LATENCY_CYCLES(2, placeholder wait around one
//   real combinational cycle) -> now 3 (three REAL 1-cycle stages) - a net
//   +1 cycle, not +3, since the old parameter was already "spending" one
//   cycle on a wait that didn't correspond to real pipeline depth.
//
//   ARITHMETIC (current milestone): the old absolute-window accumulate
//   (place_in_acc x2 + fp32_to_acc into the ACC_WIDTH=95 / ACC_ANCHOR=34
//   buffer) is REPLACED by a scale-free SLIDING-ACCUMULATOR frame, closing
//   the same truncation-at-extreme-scales class of bug that the plain-MXFP4
//   rewrite closed (the absolute window silently dropped whole scale/
//   magnitude ranges). This is the fourth sibling of the MXFP4/MXFP8/M2XFP4
//   sliding frames - see mxdotp_pkg.sv's "MXFINAL SLIDING-ACCUMULATOR FRAME"
//   section for the full derivation (anchor selection on p1==0; per-term
//   clamped placement; the three bypasses; and the from-first-principles
//   sizing MXF_FRAME_WIDTH=38, MXF_REMAIN_BITS=36, MXF_LZC_WIDTH=74).
//   Validated bit-exact RNE against an exact-rational reference
//   (mxfinal_golden.py) across 745k+ vectors, and the RTL itself confirmed
//   bit-identical to that golden model on 100k+ vectors via a Verilator TB.
//
//   BACK1 now: select the anchor (scale_exp(a,b) if p1!=0, else
//   scale_exp(ar,b) - one mux on p1==0, NOT a runtime leading-bit compare),
//   place the frame-resident product (p1, or p2 when p1==0) exactly, slide
//   the other product and the old accumulator in via the per-term clamped
//   shift, and OR their stickies. The -2 that fp4_to_code's *4 convention
//   needs is carried once by mxf_finalize's exponent term (NOT applied to
//   the anchor here - doing both would double-count it). p2/residue's
//   contribution is unconditional (no format mask; only residue-style
//   formats reach this engine post-split). BACK2/BACK3 are structurally
//   unchanged: mxf_find_lead (leading-one scan) then mxf_finalize (mantissa/
//   round/clamp), with the acc-verbatim bypass applied at BACK3.
//==============================================================================

module mxdotp_final_engine
    import mxdotp_pkg::*;
#(
    // Real system value is always 64 (mxdotp_core_top.sv -> mxdotp_xif.sv ->
    // here), same as the other two engines - matched here for consistency
    // even though, unlike mxdotp_dotp_engine.sv/mxdotp_fused_engine.sv, this
    // module never actually needs more than the low 32 bits of rs1_i/rs2_i
    // (scales/old_acc are plain 32-bit reads, never dual-read - see file
    // header) and would work correctly at 32 too. No elaboration-time
    // guard needed here for that reason.
    parameter int X_RFR_WIDTH    = 64,
    parameter int X_RFW_WIDTH    = 32,
    parameter int X_ID_WIDTH     = 4
)
(
    input  logic                   clk_i,
    input  logic                   rst_ni,

    input  logic                   start_i,
    output logic                   ready_o,
    output logic                   result_valid_o,
    input  logic                   result_ready_i,

    input  logic [X_ID_WIDTH-1:0]     id_i,
    input  logic [4:0]                rd_i,
    output logic [X_ID_WIDTH-1:0]     result_id_o,
    output logic [4:0]                result_rd_o,

    input  logic [X_RFR_WIDTH-1:0]    rs1_i,  // scales
    input  logic [X_RFR_WIDTH-1:0]    rs2_i,  // old FP32 accumulator
    input  logic signed [PSUM_WIDTH-1:0] p1_i,  // mailbox snapshot: raw sum(A.B)
    input  logic signed [PSUM_WIDTH-1:0] p2_i,  // mailbox snapshot: raw sum(AR.B)

    output logic [X_RFW_WIDTH-1:0] result_data
);

  //----------------------------------------------------------------------------
  // Input capture (on start_i) - p1_i/p2_i captured exactly like rs1_i/rs2_i;
  // see file header for why that's the entire "snapshot" mechanism.
  //----------------------------------------------------------------------------

// PIPELINE STAGES INTRODUCED (5 stages / 4 cycles latency):
// - Stage 1 (in_valid_q): Input capture. rs1_i, rs2_i, p1_i, p2_i are latched.
// - Stage 2 (back1a_valid_q): Scale decode + Shifters. The massive BACK1 combinational path is sliced in half. This stage calculates shift amounts and shifts the three terms (F, SECOND, acc), latching the three 74-bit shifted values and their stickies into back1a_*_q.
// - Stage 3 (back1b_valid_q): Wide Adder Tree. The three 74-bit shifted values are summed together into mxf_word_q.
// - Stage 4 (back2_valid_q): Leading-one scan (mxf_find_lead). Latches into lead_q.
// - Stage 5 (result_valid_q): Mantissa rounding/finalize (mxf_finalize). Latches into result_data_q.
// NEW CROSSED SIGNALS: The 74-bit shifted contributions from place_F, place_SECOND, and place_acc (and their stickies) now cross a new register boundary (back1a) before entering the wide adder tree.

  logic in_valid_q, back1a_valid_q, back1b_valid_q, back2_valid_q, result_valid_q;
  
  logic [X_ID_WIDTH-1:0] id_q1, id_q2, id_q3, id_q4, id_q5;
  logic [4:0] rd_q1, rd_q2, rd_q3, rd_q4, rd_q5;

  logic [X_RFR_WIDTH-1:0] rs1_q, rs2_q;
  logic signed [PSUM_WIDTH-1:0] p1_q, p2_q;

  // BACK1A registers
  logic signed [MXF_LZC_WIDTH-1:0] f_contrib_q, sec_contrib_q, acc_contrib_q;
  logic f_sticky_q, sec_sticky_q, acc_sticky_q;
  mx_exp_t anchor_q1;
  logic mxf_is_acc_q1;
  logic [31:0] bypass_acc_q1;

  // BACK1B registers
  logic signed [MXF_LZC_WIDTH-1:0] mxf_word_q;
  mx_exp_t                         anchor_q;
  logic                            mxf_sticky_q;
  logic                            mxf_is_acc_q;
  logic [31:0]                     bypass_acc_q;
  mxf_lead_result_t                lead_q;

  // Stage-4 (BACK2) registers. anchor_q/mxf_sticky_q/mxf_is_acc_q/
  // bypass_acc_q above settle at the SAME back1a_valid_q->back1b_valid_q
  // boundary as mxf_word_q (stage 3), but are consumed later - alongside
  // lead_q - during stage 4 (mxf_finalize_i reads acc_sticky_i/scale_exp_i,
  // and back3_result_comb reads mxf_is_acc_q/bypass_acc_q for its mux),
  // exactly where lead_q is ALSO consumed. lead_q gets that extra stage of
  // propagation (captured at the back1b_valid_q gate, alongside id_q4/
  // rd_q4); these four never did - they were left reading the stage-3
  // register directly, one stage too early. Under genuine back-to-back
  // overlap (this engine's whole point, post-pipelining) a second
  // instruction entering back1a_valid_q behind the first overwrites
  // anchor_q/mxf_sticky_q/mxf_is_acc_q/bypass_acc_q before the first
  // instruction reaches stage 4 to read them - confirmed as a real,
  // deterministic failure by tb_mxfinal_unit.sv's rewritten (overlap +
  // randomized-backpressure) unit test against the real golden model.
  mx_exp_t           anchor_q_stage4;
  logic               mxf_sticky_q_stage4;
  logic               mxf_is_acc_q_stage4;
  logic [31:0]        bypass_acc_q_stage4;

  wire stall = result_valid_q && !result_ready_i;
  
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      in_valid_q     <= 1'b0;
      back1a_valid_q <= 1'b0;
      back1b_valid_q <= 1'b0;
      back2_valid_q  <= 1'b0;
      result_valid_q <= 1'b0;
    end else if (!stall) begin
      in_valid_q     <= start_i;
      back1a_valid_q <= in_valid_q;
      back1b_valid_q <= back1a_valid_q;
      back2_valid_q  <= back1b_valid_q;
      result_valid_q <= back2_valid_q;
    end
  end

  // Comb signals for BACK1A
  logic signed [MXF_LZC_WIDTH-1:0] back1a_f_contrib_comb, back1a_sec_contrib_comb, back1a_acc_contrib_comb;
  logic back1a_f_sticky_comb, back1a_sec_sticky_comb, back1a_acc_sticky_comb;

  // Comb signals for BACK1B
  logic signed [MXF_LZC_WIDTH-1:0] back1b_word_comb;
  logic                            back1b_sticky_comb;

  // Comb signals from the operand decode, BACK1 and BACK2 further down,
  // registered by the always_ff below (declared here, ahead of that use).
  logic [31:0]      old_acc;
  mx_exp_t          back1_anchor_comb;  // the SELECTED anchor (sexp1 or sexp2)
  logic             back1_is_acc_comb;
  mxf_lead_result_t back2_lead_comb;

  always_ff @(posedge clk_i) begin
    if (!stall) begin
      if (start_i) begin
        id_q1   <= id_i;
        rd_q1   <= rd_i;
        rs1_q   <= rs1_i;
        rs2_q   <= rs2_i;
        p1_q    <= p1_i;
        p2_q    <= p2_i;
      end
      if (in_valid_q) begin
        id_q2         <= id_q1;
        rd_q2         <= rd_q1;
        f_contrib_q   <= back1a_f_contrib_comb;
        f_sticky_q    <= back1a_f_sticky_comb;
        sec_contrib_q <= back1a_sec_contrib_comb;
        sec_sticky_q  <= back1a_sec_sticky_comb;
        acc_contrib_q <= back1a_acc_contrib_comb;
        acc_sticky_q  <= back1a_acc_sticky_comb;
        anchor_q1     <= back1_anchor_comb;
        mxf_is_acc_q1 <= back1_is_acc_comb;
        bypass_acc_q1 <= old_acc;
      end
      if (back1a_valid_q) begin
        id_q3        <= id_q2;
        rd_q3        <= rd_q2;
        mxf_word_q   <= back1b_word_comb;
        mxf_sticky_q <= back1b_sticky_comb;
        anchor_q     <= anchor_q1;
        mxf_is_acc_q <= mxf_is_acc_q1;
        bypass_acc_q <= bypass_acc_q1;
      end
      if (back1b_valid_q) begin
        id_q4   <= id_q3;
        rd_q4   <= rd_q3;
        lead_q  <= back2_lead_comb;
        anchor_q_stage4     <= anchor_q;
        mxf_sticky_q_stage4 <= mxf_sticky_q;
        mxf_is_acc_q_stage4 <= mxf_is_acc_q;
        bypass_acc_q_stage4 <= bypass_acc_q;
      end
      // Result is written to result_data_q later below, handled similarly
    end
  end

  assign ready_o = !stall;
  assign result_valid_o = result_valid_q;

  //----------------------------------------------------------------------------
  // BACK1: decode rs1_q=scales / rs2_q=old_acc, apply each scale pair to
  // the captured p1_q/p2_q via place_in_acc, bring in the old accumulator
  // via fp32_to_acc, and sum at full ACC_FULL_WIDTH precision. p2/residue's
  // contribution is UNCONDITIONAL - no format check anywhere in this
  // engine - since only residue-style formats ever reach it post-split (see
  // file header / mxdotp_pkg.sv's MX_SLOT_FUSED milestone header). Feeds
  // sum_q (the X|Y cut) rather than continuing straight into the leading-
  // one scan.
  //----------------------------------------------------------------------------

  logic [7:0]  a_scale, ar_scale, b_scale;

  // Two E8M0 combined scales. NOTE: the "-2" that corrects for fp4_to_code's
  // implicit *4 per raw product (code = 2*value, so code_a*code_b =
  // 4*value_a*value_b) is NOT applied here - it is carried by mxf_finalize's
  // exponent term (lead_pos - (MXF_REMAIN_BITS + 2) + anchor), whose "+2"
  // subtracted IS exactly this code anchor. Both p1 and p2 share the *4
  // convention, so a single shared -2 in finalize covers both. (Applying -2
  // here as well would double-count it - a factor-of-4 / 2-binade error.)
  mx_exp_t sexp1, sexp2;              // scale_exp(...), the raw combined scale
  int      delta;                     // Sa - Sar >= 0 (Sar <= Sa proven)

  // acc decode (subnormals honored, exactly as the plain-MXFP4 frame does)
  logic        acc_sign;
  logic [7:0]  acc_exp_f;
  logic [22:0] acc_mant_f;
  logic        acc_is_normal;
  logic signed [24:0] smant;          // 25-bit signed: |{implicit,mant23}| <= 2^24-1
  mx_exp_t     acc_shift;

  // The three contributors' word-bit shift positions and the frame-resident
  // term / second term selected by p1==0.
  logic signed [24:0] F_val, SECOND_val;   // 25b container (products are 13b)
  int                 F_sh, SECOND_sh, acc_sh;
  logic               p1_is_zero, products_cancel;

  mxf_place_result_t  place_F, place_SECOND, place_acc;

  logic signed [MXF_LZC_WIDTH-1:0] back1_word_comb;
  logic                            back1_sticky_comb;

  always_comb begin
    a_scale  = rs1_q[31:24];
    ar_scale = rs1_q[23:16];
    b_scale  = rs1_q[15:8];
    // rs1_q[7:0] is reserved for now.
    old_acc  = rs2_q[31:0];

    sexp1 = scale_exp(a_scale,  b_scale);   // -2 code anchor is in mxf_finalize
    sexp2 = scale_exp(ar_scale, b_scale);
    delta = int'(a_scale) - int'(ar_scale);   // = Sa_raw - Sar_raw >= 0

    p1_is_zero = (p1_q == '0);

    // Anchor select (one mux, NOT a runtime leading-bit comparison): when p1
    // is present it is the frame-resident reference at sexp1 and p2 slides
    // down by delta; when p1 is exactly zero the residue term p2 is the only
    // product, so anchor at sexp2 with p2 frame-resident.
    if (!p1_is_zero) begin
      back1_anchor_comb = sexp1;
      F_val      = 25'(signed'(p1_q));
      F_sh       = MXF_REMAIN_BITS;
      SECOND_val = 25'(signed'(p2_q));
      SECOND_sh  = MXF_REMAIN_BITS - delta;    // slides DOWN (delta >= 0)
    end else begin
      back1_anchor_comb = sexp2;
      F_val      = 25'(signed'(p2_q));
      F_sh       = MXF_REMAIN_BITS;
      SECOND_val = '0;                          // p1 == 0, no second term
      SECOND_sh  = MXF_REMAIN_BITS;
    end

    // acc decode + slide, identical formula/handling to the plain-MXFP4 frame.
    acc_sign      = old_acc[31];
    acc_exp_f     = old_acc[30:23];
    acc_mant_f    = old_acc[22:0];
    acc_is_normal = (acc_exp_f != 8'd0);
    smant = acc_sign ? -$signed({1'b0, acc_is_normal, acc_mant_f})
                     :  $signed({1'b0, acc_is_normal, acc_mant_f});
    acc_shift = mx_exp_t'({8'd0, acc_exp_f}) + mx_exp_t'(!acc_is_normal)
              - mx_exp_t'(MXF_ACC_SHIFT_CONST) - back1_anchor_comb;
    acc_sh    = int'(acc_shift) + MXF_REMAIN_BITS;

    // Place all three into the extended word (F exact; SECOND and acc via the
    // per-term clamped shift + own-width sticky).
    place_F      = mxf_place(F_val,      F_sh,      13);
    place_SECOND = mxf_place(SECOND_val, SECOND_sh, 13);
    place_acc    = mxf_place(smant,      acc_sh,    25);

    back1a_f_contrib_comb   = place_F.contrib;
    back1a_f_sticky_comb    = place_F.sticky;
    back1a_sec_contrib_comb = place_SECOND.contrib;
    back1a_sec_sticky_comb  = place_SECOND.sticky;
    back1a_acc_contrib_comb = place_acc.contrib;
    back1a_acc_sticky_comb  = place_acc.sticky;

    // Bypasses (return old_acc verbatim) - see mxdotp_pkg.sv MXFINAL header:
    //   (1) acc dominates; (2) both products zero; (3) products cancel exactly.
    products_cancel = (!p1_is_zero) && (delta < 12) &&
                      (p2_q == -(PSUM_WIDTH'(p1_q <<< delta)));
    back1_is_acc_comb = (acc_shift > mx_exp_t'(MXF_MAX_ACC_SHIFT))
                      || (p1_is_zero && (p2_q == '0))
                      || products_cancel;
  end

  // BACK1B: wide adder tree
  always_comb begin
    back1b_word_comb   = f_contrib_q + sec_contrib_q + acc_contrib_q;
    back1b_sticky_comb = f_sticky_q | sec_sticky_q | acc_sticky_q;
  end

  //----------------------------------------------------------------------------
  // BACK2: leading-one scan (mxdotp_pkg.sv's acc_find_lead) on the
  // registered sum. Feeds lead_q (the Y|Z cut) rather than continuing
  // straight into mantissa extraction.
  //----------------------------------------------------------------------------

  // neg_adjust: a nonzero positive residue was floor-truncated below the
  // word (the sticky-direction fix). For MXFINAL that is simply the
  // aggregate tail sticky registered from BACK1 (any right-shifted term
  // dropped a positive residue) - see mx_find_lead / the frame header.
  mx_find_lead #(.W(MXF_LZC_WIDTH)) mxf_find_lead_i (
    .word_i       (mxf_word_q),
    .neg_adjust_i (mxf_sticky_q),
    .sign_o       (back2_lead_comb.sign),
    .lead_pos_o   (back2_lead_comb.lead_pos),
    .mag_o        (back2_lead_comb.mag)
  );

  //----------------------------------------------------------------------------
  // BACK3: mantissa extraction + sticky + round + exponent clamp
  // (mxdotp_pkg.sv's acc_finalize) on the registered leading-one-scan
  // result. Result latched into result_data_q on the done_o edge, same
  // discipline as before - never a live combinational function of captured
  // state exposed on the output port.
  //----------------------------------------------------------------------------

  logic [31:0] back3_result_comb;

  logic [31:0] back3_finalized;

  mx_finalize #(
    .W      (MXF_LZC_WIDTH),
    .REMAIN (MXF_REMAIN_BITS),
    .ANCHOR (MXF_FRAME_ANCHOR)
  ) mxf_finalize_i (
    .sign_i       (lead_q.sign),
    .lead_pos_i   (lead_q.lead_pos),
    .mag_i        (lead_q.mag),
    .acc_sticky_i (mxf_sticky_q_stage4),
    .scale_exp_i  (anchor_q_stage4),
    .result_o     (back3_finalized)
  );

  // Bypass wins over the frame result: when BACK1 flagged acc-dominates /
  // products-zero / products-cancel-exact, the correct result is the old
  // accumulator verbatim (registered in bypass_acc_q). Otherwise the
  // finalized frame word, with the scale (anchor) re-entering on the
  // exponent only and the aggregate sticky ORed into the round decision.
  assign back3_result_comb = mxf_is_acc_q_stage4 ? bypass_acc_q_stage4 : back3_finalized;

  logic [X_RFW_WIDTH-1:0] result_data_q;

  always_ff @(posedge clk_i) begin
    if (!stall && back2_valid_q) begin
      id_q5 <= id_q4;
      rd_q5 <= rd_q4;
      result_data_q <= back3_result_comb;
    end
  end

  assign result_data = result_data_q;
  assign result_id_o = id_q5;
  assign result_rd_o = rd_q5;


  // synthesis translate_off
  //----------------------------------------------------------------------------
  // Reset-discipline check. The datapath in this engine carries no reset, which
  // is only sound if data is never observed on a beat that claims to be
  // meaningful before that data has been written. This assertion is what turns
  // that from an assumption into a checked property: it fires the moment an X
  // escapes on such a beat.
  //
  // Under Verilator (2-state) this is vacuous, so `make` will not exercise it;
  // it earns its keep in a 4-state simulator (Questa/VCS/Xcelium) and in
  // gate-level sim - exactly where an unreset-register bug would otherwise hide.
  //----------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && result_valid_q) begin
      assert (!$isunknown(result_data_q)) else
        $error("%m: X on the result being latched - an unreset datapath register was read before it was written");
    end
  end
  // synthesis translate_on

endmodule
