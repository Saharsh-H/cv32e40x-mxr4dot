//==============================================================================
// File    : mx_syn_mxfinal.sv
// Project : MXDOTP XIF Coprocessor - standalone synthesis harness
//------------------------------------------------------------------------------
// SYNTHESIS SCAFFOLDING - NOT DESIGN RTL. See mx_syn_fp4.sv for full rationale.
//
// The mxfinal engine (mxdotp_final_engine.sv) on its own. Its p1_i/p2_i (the
// mailbox head in the system) are plain top-level inputs here; the pair with
// the real mailbox is mx_syn_pair.sv.
//
// Pure passthrough of the HEAD ports, parameters pinned to the values
// mxdotp_xif.sv / mxdotp_core_top.sv use. The engine's output port is named
// result_data (no _o); it is brought out as result_data_o like the others.
//==============================================================================

module mx_syn_mxfinal
  import mxdotp_pkg::*;
#(
  parameter int X_RFR_WIDTH = 64,    // pinned: mxdotp_core_top.sv
  parameter int X_RFW_WIDTH = 32,    // pinned: single-write result width
  parameter int X_ID_WIDTH  = 4      // pinned: mxdotp_core_top.sv
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic                         start_i,
  output logic                         ready_o,
  output logic                         result_valid_o,
  input  logic                         result_ready_i,
  input  logic [X_ID_WIDTH-1:0]        id_i,
  input  logic [4:0]                   rd_i,
  output logic [X_ID_WIDTH-1:0]        result_id_o,
  output logic [4:0]                   result_rd_o,

  input  logic [X_RFR_WIDTH-1:0]       rs1_i,     // scales
  input  logic [X_RFR_WIDTH-1:0]       rs2_i,     // old FP32 accumulator
  input  logic signed [PSUM_WIDTH-1:0] p1_i,      // mailbox head: raw sum(A.B)
  input  logic signed [PSUM_WIDTH-1:0] p2_i,      // mailbox head: raw sum(AR.B)
  output logic [X_RFW_WIDTH-1:0]       result_data_o
);

  mxdotp_final_engine #(
    .X_RFR_WIDTH (X_RFR_WIDTH),
    .X_RFW_WIDTH (X_RFW_WIDTH),
    .X_ID_WIDTH  (X_ID_WIDTH)
  ) dut (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .start_i        (start_i),
    .ready_o        (ready_o),
    .result_valid_o (result_valid_o),
    .result_ready_i (result_ready_i),
    .id_i           (id_i),
    .rd_i           (rd_i),
    .result_id_o    (result_id_o),
    .result_rd_o    (result_rd_o),
    .rs1_i          (rs1_i),
    .rs2_i          (rs2_i),
    .p1_i           (p1_i),
    .p2_i           (p2_i),
    .result_data    (result_data_o)
  );

endmodule
