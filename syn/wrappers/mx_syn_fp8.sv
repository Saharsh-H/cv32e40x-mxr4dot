//==============================================================================
// File    : mx_syn_fp8.sv
// Project : MXDOTP XIF Coprocessor - Phase A' standalone synthesis harness
//------------------------------------------------------------------------------
// SYNTHESIS SCAFFOLDING - NOT DESIGN RTL. Never add this file (or anything else
// under syn/) to MXDOTP_SRCS, the cv32e40x manifest, or any simulation build.
// It exists only so ONE engine can be synthesized standalone, to get per-engine
// area/timing/power that a flattened whole-subsystem run cannot attribute.
//
// Why a wrapper at all, rather than synthesizing the engine directly as top:
//
//   1. MODULE NAME != FILE NAME. mxdotp_fp4_fused_engine.sv declares a module
//      called `mxdotp_fused_engine` (the DECLFILENAME warning seen in the
//      lint output reports). A synthesis script pointed at "the fp4 engine"
//      would need to know that mismatch. mx_syn_fp8 is a predictable name.
//
//   2. PARAMETER PINNING. Every engine's own defaults happen to match the
//      deployed values today (X_ID_WIDTH=4 / X_RFR_WIDTH=64 / X_RFW_WIDTH=32,
//      per mxdotp_core_top.sv), so a bare synthesis would be correct - but by
//      coincidence, not by construction. Note mxdotp_xif.sv's OWN default for
//      X_RFR_WIDTH is 32, not 64; the 64 comes from core_top overriding it. If
//      an engine default ever drifts, a bare run would silently characterize a
//      design that is not the one in the chip. These are pinned explicitly.
//
// The wrapper is a pure passthrough - every engine port maps 1:1 to a top port
// with no added logic. That is deliberate: any boundary registers added here
// would land in the area number and misattribute engine cost. The engines
// already register their own inputs (rs1_q/rs2_q/rs3_q on capture) and outputs
// (result_data_q), so the real critical paths are internal register-to-register
// and are measured correctly without extra scaffolding. I/O timing is handled
// by set_input_delay/set_output_delay in constraints/mx.sdc, not here.
//==============================================================================

module mx_syn_fp8 #(
  parameter int X_ID_WIDTH  = 4,     // pinned: mxdotp_core_top.sv
  parameter int X_RFR_WIDTH = 64,    // pinned: dual-read operand width (2*XLEN)
  parameter int X_RFW_WIDTH = 32     // pinned: single-write result width
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  input  logic                    start_i,
  output logic                    ready_o,
  input  logic [X_ID_WIDTH-1:0]   id_i,
  input  logic [4:0]              rd_i,
  input  logic [X_RFR_WIDTH-1:0]  rs1_i,
  input  logic [X_RFR_WIDTH-1:0]  rs2_i,
  input  logic [X_RFR_WIDTH-1:0]  rs3_i,
  input  logic [1:0]              mx_format_i,

  output logic                    result_valid_o,
  input  logic                    result_ready_i,
  output logic [X_ID_WIDTH-1:0]   result_id_o,
  output logic [4:0]              result_rd_o,
  output logic [X_RFW_WIDTH-1:0]  result_data_o
);

  // MXFP8 engine, from mxdotp_fp8_fused_engine.sv.
  mxdotp_fp8_fused_engine #(
    .X_ID_WIDTH  (X_ID_WIDTH),
    .X_RFR_WIDTH (X_RFR_WIDTH),
    .X_RFW_WIDTH (X_RFW_WIDTH)
  ) dut (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .start_i        (start_i),
    .ready_o        (ready_o),
    .id_i           (id_i),
    .rd_i           (rd_i),
    .rs1_i          (rs1_i),
    .rs2_i          (rs2_i),
    .rs3_i          (rs3_i),
    .mx_format_i    (mx_format_i),
    .result_valid_o (result_valid_o),
    .result_ready_i (result_ready_i),
    .result_id_o    (result_id_o),
    .result_rd_o    (result_rd_o),
    .result_data_o  (result_data_o)
  );

endmodule
