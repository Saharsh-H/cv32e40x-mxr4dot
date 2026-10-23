//==============================================================================
// File    : mx_syn_dotp.sv
// Project : MXDOTP XIF Coprocessor - standalone synthesis harness
//------------------------------------------------------------------------------
// SYNTHESIS SCAFFOLDING - NOT DESIGN RTL. See mx_syn_fp4.sv for full rationale.
//
// The mxresdot engine (mxdotp_dotp_engine.sv) on its own: two 16-element
// MXFP4 dot products, p1 = sum(A.B) and p2 = sum(AR.B), raw and unscaled.
// It produces no architectural result by itself - its p1/p2 go through the
// mailbox to mxfinal - so its numbers are a component of the residue pair,
// not a format of their own. The pair as one design is mx_syn_pair.sv.
//
// Pure passthrough of the HEAD ports (ready/valid handshake, id), parameters
// pinned to the values mxdotp_xif.sv / mxdotp_core_top.sv use.
//==============================================================================

module mx_syn_dotp
  import mxdotp_pkg::*;
#(
  parameter int X_RFR_WIDTH = 64,    // pinned: mxdotp_core_top.sv
  parameter int X_ID_WIDTH  = 4      // pinned: mxdotp_core_top.sv
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic                         start_i,
  output logic                         ready_o,
  output logic                         result_valid_o,
  input  logic                         result_ready_i,
  input  logic [X_ID_WIDTH-1:0]        id_i,
  output logic [X_ID_WIDTH-1:0]        result_id_o,

  input  logic [X_RFR_WIDTH-1:0]       rs1_i,     // A
  input  logic [X_RFR_WIDTH-1:0]       rs2_i,     // B
  input  logic [X_RFR_WIDTH-1:0]       rs3_i,     // AR
  output logic signed [PSUM_WIDTH-1:0] p1_o,
  output logic signed [PSUM_WIDTH-1:0] p2_o
);

  mxdotp_dotp_engine #(
    .X_RFR_WIDTH (X_RFR_WIDTH),
    .X_ID_WIDTH  (X_ID_WIDTH)
  ) dut (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .start_i        (start_i),
    .ready_o        (ready_o),
    .result_valid_o (result_valid_o),
    .result_ready_i (result_ready_i),
    .id_i           (id_i),
    .result_id_o    (result_id_o),
    .rs1_i          (rs1_i),
    .rs2_i          (rs2_i),
    .rs3_i          (rs3_i),
    .p1_o           (p1_o),
    .p2_o           (p2_o)
  );

endmodule
