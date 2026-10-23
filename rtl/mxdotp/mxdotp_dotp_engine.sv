//==============================================================================
// File    : mxdotp_dotp_engine.sv
// Project : MXDOTP XIF Coprocessor
//------------------------------------------------------------------------------
// Description:
//   Standalone MXDOTP arithmetic engine - the DOTP half of what used to be
//   one shared mxdotp_execute module. See mxdotp_xif.sv's "pipelined
//   coprocessor" milestone header (mxdotp_pkg.sv) for why this was split out:
//   giving MXDOTP its own independent handshake (start_i/ready_o in,
//   result_valid_o/result_ready_i out; once start_i/busy_o/done_o) instead of
//   sharing one with MXFINAL is what actually lets a new MXDOTP begin while
//   a previous MXFINAL is still computing - splitting the RTL into separate
//   files alone would not have achieved that; independent *control* is the
//   part that matters.
//
//   rs1=A, rs2=B, rs3=AR - ALL 64-bit dual-read, MX_K=16 MXFP4 elements each,
//   regardless of format (unified ISA - see mxdotp_pkg.sv). Converts every
//   element via fp4_to_code (exact fixed-point "2*value" integer, no
//   floating intermediate needed), computes p1 = sum(A_i*B_i) and
//   p2 = sum(AR_i*B_i) as raw, UNSCALED fixed-point sums - no scale
//   knowledge exists in this engine at all; that's entirely MXFINAL's
//   concern. AR/p2 are computed unconditionally even when the format doesn't
//   use residue - this engine doesn't know or care about format; only
//   MXFINAL's dispatch does.
//==============================================================================

module mxdotp_dotp_engine
    import mxdotp_pkg::*;
#(
    // Real system value is always 64 (mxdotp_core_top.sv -> mxdotp_xif.sv ->
    // here) - this module's own unpacking is hard-fixed to MX_K=16 nibbles
    // per operand (16*4=64 bits), so 64 is the only value that actually
    // works, not an independent tunable. The default matches that rather
    // than an arbitrary smaller placeholder (32 doesn't work at all - see
    // the elaboration-time assert below, added after standalone Vivado
    // synthesis of just this module - no mxdotp_xif.sv around to supply
    // the real override - silently fell back to an old, invalid default
    // and Vivado correctly flagged the resulting out-of-range part-select).
    parameter int X_RFR_WIDTH    = 64,
    parameter int X_ID_WIDTH     = 4
)
(
    input  logic                   clk_i,
    input  logic                   rst_ni,

    input  logic                   start_i,
    output logic                   ready_o,
    output logic                   result_valid_o,
    input  logic                   result_ready_i,

    input  logic [X_ID_WIDTH-1:0]  id_i,
    output logic [X_ID_WIDTH-1:0]  result_id_o,

    input  logic [X_RFR_WIDTH-1:0] rs1_i,  // A
    input  logic [X_RFR_WIDTH-1:0] rs2_i,  // B
    input  logic [X_RFR_WIDTH-1:0] rs3_i,  // AR

    output logic signed [PSUM_WIDTH-1:0] p1_o,
    output logic signed [PSUM_WIDTH-1:0] p2_o
);

  // Elaboration-time guard: this module's unpacking is hard-fixed to
  // MX_K=16 nibbles per operand (16*4=64 bits) - X_RFR_WIDTH is not an
  // independently free parameter, it must be >= 64. Catches exactly the
  // failure mode a standalone Vivado synthesis run just hit (module's own
  // default silently too small, no mxdotp_xif.sv around to supply the real
  // override) with a clear message instead of a bare out-of-range
  // part-select error deep in the unpacking loop.
  // synthesis translate_off
  initial begin
    assert (X_RFR_WIDTH >= 64) else
      $error("mxdotp_dotp_engine: X_RFR_WIDTH (%0d) must be >= 64 - MX_K=16 nibbles per operand need the full 64 bits, this is not a free parameter.",
              X_RFR_WIDTH);
  end
  // synthesis translate_on

// PIPELINE STAGES INTRODUCED (5 stages / 4 cycles latency):
// - Stage 1 (in_valid_q): Input capture. rs1_i, rs2_i, rs3_i are latched into rs1_q, rs2_q, rs3_q.
// - Stage 2 (st2_valid_q): Multipliers + 1st reduction (16->8). 16 terms are multiplied and reduced to 8 sums, latched into st2_p1_q[0..7] and st2_p2_q[0..7].
// - Stage 3 (st3_valid_q): 2nd reduction (8->4). 8 sums are reduced to 4 sums, latched into st3_p1_q[0..3] and st3_p2_q[0..3].
// - Stage 4 (st4_valid_q): 3rd reduction (4->2). 4 sums are reduced to 2 sums, latched into st4_p1_q[0..1] and st4_p2_q[0..1].
// - Stage 5 (result_valid_q): 4th reduction (2->1). 2 sums are reduced to 1 final sum, latched into p1_q and p2_q.
// NEW CROSSED SIGNALS: The 8-term (st2), 4-term (st3), and 2-term (st4) intermediate sums now cross new register boundaries to break the massive 2.14 ns combinational adder tree.

  //----------------------------------------------------------------------------
  // Pipelined control and data capture
  //----------------------------------------------------------------------------

  logic in_valid_q;
  logic st2_valid_q;
  logic st3_valid_q;
  logic st4_valid_q;
  logic result_valid_q;

  logic [X_ID_WIDTH-1:0] id_q1, id_q2, id_q3, id_q4, id_q5;
  logic [X_RFR_WIDTH-1:0] rs1_q, rs2_q, rs3_q;

  logic signed [PSUM_WIDTH-1:0] st2_p1_q [0:7];
  logic signed [PSUM_WIDTH-1:0] st2_p2_q [0:7];

  logic signed [PSUM_WIDTH-1:0] st3_p1_q [0:3];
  logic signed [PSUM_WIDTH-1:0] st3_p2_q [0:3];

  logic signed [PSUM_WIDTH-1:0] st4_p1_q [0:1];
  logic signed [PSUM_WIDTH-1:0] st4_p2_q [0:1];

  logic signed [PSUM_WIDTH-1:0] p1_q, p2_q;

  wire stall = result_valid_q && !result_ready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      in_valid_q     <= 1'b0;
      st2_valid_q    <= 1'b0;
      st3_valid_q    <= 1'b0;
      st4_valid_q    <= 1'b0;
      result_valid_q <= 1'b0;
    end else if (!stall) begin
      in_valid_q     <= start_i;
      st2_valid_q    <= in_valid_q;
      st3_valid_q    <= st2_valid_q;
      st4_valid_q    <= st3_valid_q;
      result_valid_q <= st4_valid_q;
    end
  end

  // Combinational intermediates
  logic signed [PSUM_WIDTH-1:0] st2_p1_comb [0:7];
  logic signed [PSUM_WIDTH-1:0] st2_p2_comb [0:7];
  logic signed [PSUM_WIDTH-1:0] st3_p1_comb [0:3];
  logic signed [PSUM_WIDTH-1:0] st3_p2_comb [0:3];
  logic signed [PSUM_WIDTH-1:0] st4_p1_comb [0:1];
  logic signed [PSUM_WIDTH-1:0] st4_p2_comb [0:1];
  logic signed [PSUM_WIDTH-1:0] result_p1_comb;
  logic signed [PSUM_WIDTH-1:0] result_p2_comb;

  always_ff @(posedge clk_i) begin
    if (!stall) begin
      if (start_i) begin
        id_q1 <= id_i;
        rs1_q <= rs1_i;
        rs2_q <= rs2_i;
        rs3_q <= rs3_i;
      end
      if (in_valid_q) begin
        id_q2    <= id_q1;
        st2_p1_q <= st2_p1_comb;
        st2_p2_q <= st2_p2_comb;
      end
      if (st2_valid_q) begin
        id_q3    <= id_q2;
        st3_p1_q <= st3_p1_comb;
        st3_p2_q <= st3_p2_comb;
      end
      if (st3_valid_q) begin
        id_q4    <= id_q3;
        st4_p1_q <= st4_p1_comb;
        st4_p2_q <= st4_p2_comb;
      end
      if (st4_valid_q) begin
        id_q5 <= id_q4;
        p1_q  <= result_p1_comb;
        p2_q  <= result_p2_comb;
      end
    end
  end

  assign ready_o = !stall;
  assign result_valid_o = result_valid_q;
  assign result_id_o = id_q5;

  //----------------------------------------------------------------------------
  // Datapath (Pipelined Adder Tree)
  //----------------------------------------------------------------------------

  logic [3:0] a_nib  [0:MX_K-1];
  logic [3:0] b_nib  [0:MX_K-1];
  logic [3:0] ar_nib [0:MX_K-1];

  logic signed [CODE_WIDTH-1:0] a_code  [0:MX_K-1];
  logic signed [CODE_WIDTH-1:0] b_code  [0:MX_K-1];
  logic signed [CODE_WIDTH-1:0] ar_code [0:MX_K-1];

  logic signed [PROD_WIDTH-1:0] p1_term [0:MX_K-1];
  logic signed [PROD_WIDTH-1:0] p2_term [0:MX_K-1];

  int i;

  always_comb begin
    // STAGE 2 COMB: 16->8 Reduction
    for (i = 0; i < MX_K; i++) begin
      a_nib[i]  = rs1_q[4*i +: 4];
      b_nib[i]  = rs2_q[4*i +: 4];
      ar_nib[i] = rs3_q[4*i +: 4];
      a_code[i]  = fp4_to_code(a_nib[i]);
      b_code[i]  = fp4_to_code(b_nib[i]);
      ar_code[i] = fp4_to_code(ar_nib[i]);
      p1_term[i] = PROD_WIDTH'(a_code[i]  * b_code[i]);
      p2_term[i] = PROD_WIDTH'(ar_code[i] * b_code[i]);
    end

    for (i = 0; i < 8; i++) begin
      st2_p1_comb[i] = PSUM_WIDTH'(p1_term[2*i]) + PSUM_WIDTH'(p1_term[2*i+1]);
      st2_p2_comb[i] = PSUM_WIDTH'(p2_term[2*i]) + PSUM_WIDTH'(p2_term[2*i+1]);
    end

    // STAGE 3 COMB: 8->4 Reduction
    for (i = 0; i < 4; i++) begin
      st3_p1_comb[i] = st2_p1_q[2*i] + st2_p1_q[2*i+1];
      st3_p2_comb[i] = st2_p2_q[2*i] + st2_p2_q[2*i+1];
    end

    // STAGE 4 COMB: 4->2 Reduction
    for (i = 0; i < 2; i++) begin
      st4_p1_comb[i] = st3_p1_q[2*i] + st3_p1_q[2*i+1];
      st4_p2_comb[i] = st3_p2_q[2*i] + st3_p2_q[2*i+1];
    end

    // STAGE 5 COMB: 2->1 Reduction
    result_p1_comb = st4_p1_q[0] + st4_p1_q[1];
    result_p2_comb = st4_p2_q[0] + st4_p2_q[1];
  end

  //----------------------------------------------------------------------------
  // Pipeline output
  //----------------------------------------------------------------------------

  assign p1_o = p1_q;
  assign p2_o = p2_q;

  // synthesis translate_off
  //----------------------------------------------------------------------------
  // Reset-discipline check, mirroring mxdotp_final_engine.sv's own version
  // verbatim (same "no reset on the datapath itself, only on the valid
  // bits" discipline here: st2_p1_q/st2_p2_q/st3_*/st4_*/p1_q/p2_q are never
  // reset, which is only sound if a beat claiming to be meaningful
  // (result_valid_q) is never observed before that data has genuinely been
  // written). This assertion is what turns that from an assumption into a
  // checked property: it fires the moment an X escapes on such a beat.
  //
  // Under Verilator (2-state) this is vacuous, so `make` will not exercise
  // it; it earns its keep in a 4-state simulator (Questa/VCS/Xcelium) and in
  // gate-level sim - exactly where an unreset-register bug would otherwise
  // hide.
  //----------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni && result_valid_q) begin
      assert (!$isunknown(p1_q) && !$isunknown(p2_q)) else
        $error("%m: X on the result being latched - an unreset datapath register was read before it was written");
    end
  end
  // synthesis translate_on

endmodule
