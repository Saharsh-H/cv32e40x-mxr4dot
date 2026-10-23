//==============================================================================
// File    : mx_syn_pair.sv
// Project : MXDOTP XIF Coprocessor - standalone synthesis harness
//------------------------------------------------------------------------------
// SYNTHESIS SCAFFOLDING - NOT DESIGN RTL. See mx_syn_fp4.sv for the rationale
// behind the wrappers in general.
//
// The MXFP4R residue pair as ONE design: mxresdot engine + the DOTP->FINAL
// mailbox (mxdotp_mailbox.sv, the same module mxdotp_xif.sv instantiates) +
// mxfinal engine. Synthesising the two engines separately and adding their
// areas leaves the mailbox out and times the pair as its slower half; this
// design has neither problem.
//
// Unlike the other wrappers this one is not a pure passthrough: it carries the
// glue mxdotp_xif.sv puts between the two engines and the mailbox, copied
// expression for expression (mxdotp_xif.sv lines quoted below). Everything
// else the xif adds (pending-commit queues, order queue, XIF channels) is
// outside the pair and appears here as plain ports:
//   dotp_result_ready_i  = dotp_result_ready_xif (DOTP slot at the order-queue
//                          head and the core accepting the result);
//   final_start_i        = final_pending_head_ok (a committed MXFINAL waiting);
//   final_result_ready_i = final_result_ready (FINAL slot at the head, core
//                          accepting).
// p1/p2 never leave the design.
//==============================================================================

module mx_syn_pair
  import mxdotp_pkg::*;
#(
  parameter int X_RFR_WIDTH   = 64,  // pinned: mxdotp_core_top.sv
  parameter int X_RFW_WIDTH   = 32,  // pinned: single-write result width
  parameter int X_ID_WIDTH    = 4,   // pinned: mxdotp_core_top.sv
  parameter int MAILBOX_DEPTH = 4    // pinned: mxdotp_xif.sv MAILBOX_DEPTH
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,

  // mxresdot side
  input  logic                   dotp_start_i,
  output logic                   dotp_ready_o,
  input  logic [X_ID_WIDTH-1:0]  dotp_id_i,
  input  logic [X_RFR_WIDTH-1:0] dotp_rs1_i,          // A
  input  logic [X_RFR_WIDTH-1:0] dotp_rs2_i,          // B
  input  logic [X_RFR_WIDTH-1:0] dotp_rs3_i,          // AR
  output logic                   dotp_result_valid_o, // offered on the XIF result channel
  input  logic                   dotp_result_ready_i,
  output logic [X_ID_WIDTH-1:0]  dotp_result_id_o,

  // mxfinal side
  input  logic                   final_start_i,
  output logic                   final_ready_o,       // a start would be taken this cycle
  input  logic [X_ID_WIDTH-1:0]  final_id_i,
  input  logic [4:0]             final_rd_i,
  input  logic [X_RFR_WIDTH-1:0] final_rs1_i,         // scales
  input  logic [X_RFR_WIDTH-1:0] final_rs2_i,         // old FP32 accumulator
  output logic                   final_result_valid_o,
  input  logic                   final_result_ready_i,
  output logic [X_ID_WIDTH-1:0]  final_result_id_o,
  output logic [4:0]             final_result_rd_o,
  output logic [X_RFW_WIDTH-1:0] final_result_data_o
);

  logic                         mailbox_full, mailbox_valid;
  logic signed [PSUM_WIDTH-1:0] mailbox_p1, mailbox_p2;
  logic signed [PSUM_WIDTH-1:0] dotp_p1, dotp_p2;
  logic                         dotp_engine_result_valid;
  logic                         final_engine_ready;
  logic                         final_start;

  // mxdotp_xif.sv: wire dotp_result_fire = dotp_result_valid && !mailbox_full && dotp_result_ready_xif;
  //                wire mailbox_push = dotp_result_fire;
  wire mailbox_push = dotp_engine_result_valid && !mailbox_full && dotp_result_ready_i;
  // mxdotp_xif.sv: assign final_engine_start = final_pending_head_ok && mailbox_valid_q && final_engine_ready;
  //                wire mailbox_pop = final_engine_start;
  assign final_start = final_start_i && mailbox_valid && final_engine_ready;
  // mxdotp_xif.sv: the DOTP XIF result is offered only "if (dotp_result_valid && !mailbox_full)"
  assign dotp_result_valid_o = dotp_engine_result_valid && !mailbox_full;
  assign final_ready_o       = mailbox_valid && final_engine_ready;

  mxdotp_dotp_engine #(
    .X_RFR_WIDTH (X_RFR_WIDTH),
    .X_ID_WIDTH  (X_ID_WIDTH)
  ) dotp_engine_i (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .start_i        (dotp_start_i),
    .ready_o        (dotp_ready_o),
    .result_valid_o (dotp_engine_result_valid),
    // mxdotp_xif.sv: .result_ready_i (!mailbox_full && dotp_result_ready_xif)
    .result_ready_i (!mailbox_full && dotp_result_ready_i),
    .id_i           (dotp_id_i),
    .result_id_o    (dotp_result_id_o),
    .rs1_i          (dotp_rs1_i),
    .rs2_i          (dotp_rs2_i),
    .rs3_i          (dotp_rs3_i),
    .p1_o           (dotp_p1),
    .p2_o           (dotp_p2)
  );

  mxdotp_mailbox #(
    .DEPTH (MAILBOX_DEPTH)
  ) mailbox_i (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .push_i    (mailbox_push),
    .push_p1_i (dotp_p1),
    .push_p2_i (dotp_p2),
    .pop_i     (final_start),
    .full_o    (mailbox_full),
    .valid_o   (mailbox_valid),
    .head_p1_o (mailbox_p1),
    .head_p2_o (mailbox_p2)
  );

  mxdotp_final_engine #(
    .X_RFR_WIDTH (X_RFR_WIDTH),
    .X_RFW_WIDTH (X_RFW_WIDTH),
    .X_ID_WIDTH  (X_ID_WIDTH)
  ) final_engine_i (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .start_i        (final_start),
    .ready_o        (final_engine_ready),
    .result_valid_o (final_result_valid_o),
    .result_ready_i (final_result_ready_i),
    .id_i           (final_id_i),
    .rd_i           (final_rd_i),
    .result_id_o    (final_result_id_o),
    .result_rd_o    (final_result_rd_o),
    .rs1_i          (final_rs1_i),
    .rs2_i          (final_rs2_i),
    .p1_i           (mailbox_p1),
    .p2_i           (mailbox_p2),
    .result_data    (final_result_data_o)
  );

endmodule
