//==============================================================================
// File    : mx_syn_xif.sv
// Project : MXDOTP XIF Coprocessor - standalone synthesis harness
//------------------------------------------------------------------------------
// SYNTHESIS SCAFFOLDING - NOT DESIGN RTL. Never add this file (or anything else
// under syn/) to MXDOTP_SRCS, the cv32e40x manifest, or any simulation build.
//
// The whole coprocessor as one design: mxdotp_xif with every engine (dotp,
// mailbox, mxfinal, fp4, fp8, m2), the decoder, the issue/commit/result logic,
// the order queue and the result mux - the integrated design whose timing
// closure the per-engine and pair runs do not show.
//
// mxdotp_xif connects through if_xif modports, which cannot be top-level ports
// of a synthesized design. This wrapper owns one if_xif instance with the same
// parameters as mxdotp_core_top.sv (X_NUM_RS 3, X_ID_WIDTH 4, X_MEM_WIDTH 32,
// X_RFR_WIDTH 64, X_RFW_WIDTH 32, X_MISA 0, X_ECS_XS 0) and maps every
// coprocessor-side signal 1:1 to a flat port. No added logic, no registers.
// The compressed interface is not used by mxdotp_xif (it has no compressed
// port); its core-side inputs are tied to 0 so no net is left undriven.
//
// Port widths = $bits of the if_xif packed structs for these parameters:
//   issue_req  32+2+4+3*64+3+6+1 = 240   issue_resp 7
//   commit     4+1               = 5
//   mem_req    4+32+2+1+2+32+1+1 = 75    mem_resp   1+6+1 = 8
//   mem_result 4+32+1+1          = 38
//   result     4+32+5+1+6+3+1+6  = 58
// A wrong width shows up as a width-mismatch warning at elaboration.
//==============================================================================

module mx_syn_xif (
  input  logic          clk_i,
  input  logic          rst_ni,

  input  logic          issue_valid_i,
  output logic          issue_ready_o,
  input  logic [239:0]  issue_req_i,
  output logic [6:0]    issue_resp_o,

  input  logic          commit_valid_i,
  input  logic [4:0]    commit_i,

  output logic          mem_valid_o,
  input  logic          mem_ready_i,
  output logic [74:0]   mem_req_o,
  input  logic [7:0]    mem_resp_i,

  input  logic          mem_result_valid_i,
  input  logic [37:0]   mem_result_i,

  output logic          result_valid_o,
  input  logic          result_ready_i,
  output logic [57:0]   result_o
);

  localparam int          X_NUM_RS    = 3;
  localparam int          X_ID_WIDTH  = 4;
  localparam int          X_MEM_WIDTH = 32;
  localparam int          X_RFR_WIDTH = 64;
  localparam int          X_RFW_WIDTH = 32;
  localparam logic [31:0] X_MISA      = 32'h0000_0000;
  localparam logic [1:0]  X_ECS_XS    = 2'b00;

  if_xif #(
    .X_NUM_RS    ( X_NUM_RS    ),
    .X_ID_WIDTH  ( X_ID_WIDTH  ),
    .X_MEM_WIDTH ( X_MEM_WIDTH ),
    .X_RFR_WIDTH ( X_RFR_WIDTH ),
    .X_RFW_WIDTH ( X_RFW_WIDTH ),
    .X_MISA      ( X_MISA      ),
    .X_ECS_XS    ( X_ECS_XS    )
  ) xif ();

  // core side -> coprocessor
  assign xif.issue_valid      = issue_valid_i;
  assign xif.issue_req        = issue_req_i;
  assign xif.commit_valid     = commit_valid_i;
  assign xif.commit           = commit_i;
  assign xif.mem_ready        = mem_ready_i;
  assign xif.mem_resp         = mem_resp_i;
  assign xif.mem_result_valid = mem_result_valid_i;
  assign xif.mem_result       = mem_result_i;
  assign xif.result_ready     = result_ready_i;
  assign xif.compressed_valid = 1'b0;
  assign xif.compressed_req   = '0;

  // coprocessor -> core side
  assign issue_ready_o  = xif.issue_ready;
  assign issue_resp_o   = xif.issue_resp;
  assign mem_valid_o    = xif.mem_valid;
  assign mem_req_o      = xif.mem_req;
  assign result_valid_o = xif.result_valid;
  assign result_o       = xif.result;

  mxdotp_xif #(
    .X_ID_WIDTH  ( X_ID_WIDTH  ),
    .X_RFR_WIDTH ( X_RFR_WIDTH ),
    .X_RFW_WIDTH ( X_RFW_WIDTH )
  ) dut (
    .clk_i         ( clk_i                 ),
    .rst_ni        ( rst_ni                ),
    .issue_if      ( xif.coproc_issue      ),
    .commit_if     ( xif.coproc_commit     ),
    .result_if     ( xif.coproc_result     ),
    .mem_if        ( xif.coproc_mem        ),
    .mem_result_if ( xif.coproc_mem_result )
  );

endmodule
