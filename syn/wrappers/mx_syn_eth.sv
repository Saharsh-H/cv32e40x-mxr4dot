//==============================================================================
// File    : mx_syn_eth.sv
// Project : MXDOTP XIF Coprocessor - standalone synthesis harness
//------------------------------------------------------------------------------
// SYNTHESIS SCAFFOLDING - NOT DESIGN RTL. Baseline for comparison only.
//
// Configuration as shipped (package defaults): sources FP8 (E5M2, E4M3), FP6 (E3M2, E2M3),
// FP4 (E2M1), INT8; destination FP32 and FP16ALT; 8 elements per operation.
//
// Unit: ETH Zurich / University of Bologna MXDOTP, mxdotp_multi_wrapper.sv and
// its sources, unchanged, in syn/third_party/eth_mxdotp/ (provenance in the
// README there). Pipeline as shipped: NumPipeRegs = 3, PipeConfig = DISTRIBUTED
// (one register stage each at input, middle and output).
//
// Pure passthrough, same convention as the other mx_syn_* wrappers: every port
// of the unit maps 1:1 to a top port, no added logic, no registers.
//==============================================================================

module mx_syn_eth
  import fpnew_mxdotp_multi_pkg::*;
(
  input  logic                                     clk_i,
  input  logic                                     rst_ni,
  input  logic [VectorSize-1:0][SRC_WIDTH-1:0]     operands_a_i,
  input  logic [VectorSize-1:0][SRC_WIDTH-1:0]     operands_b_i,
  input  logic [1:0]                               operands_a_fp6_rem_i,
  input  logic [1:0]                               operands_b_fp6_rem_i,
  input  logic [1:0][SCALE_WIDTH-1:0]              operands_c_i,
  input  logic [DST_WIDTH-1:0]                     operand_d_i,
  input  logic [NUM_FORMATS-1:0][NUM_OPERANDS-1:0] is_boxed_i,
  input  fpnew_pkg::roundmode_e                    rnd_mode_i,
  input  fpnew_pkg::operation_e                    op_i,
  input  logic                                     op_mod_i,
  input  fpnew_pkg::fp_format_e                    src_fmt_i,
  input  fpnew_pkg::int_format_e                   int_fmt_i,
  input  fpnew_pkg::fp_format_e                    dst_fmt_i,
  input  logic                                     tag_i,
  input  logic                                     mask_i,
  input  logic                                     aux_i,
  input  logic                                     in_valid_i,
  output logic                                     in_ready_o,
  input  logic                                     flush_i,
  output logic [DST_WIDTH-1:0]                     result_o,
  output fpnew_pkg::status_t                       status_o,
  output logic                                     extension_bit_o,
  output logic                                     tag_o,
  output logic                                     mask_o,
  output logic                                     aux_o,
  output logic                                     out_valid_o,
  input  logic                                     out_ready_i,
  output logic                                     busy_o
);

  mxdotp_multi_wrapper #(
    .FpSrcFmtConfig  ( MxdotpSrcFpFmtConfig     ), // 9'b000101111
    .IntSrcFmtConfig ( MxdotpSrcIntFmtConfig    ), // 4'b1000
    .FpDstFmtConfig  ( MxdotpDstFpFmtConfig     ), // 9'b100010000
    .NumPipeRegs     ( 3                        ),
    .PipeConfig      ( fpnew_pkg::DISTRIBUTED   ),
    .TagType         ( logic                    ),
    .AuxType         ( logic                    )
  ) dut (
    .clk_i                ( clk_i                ),
    .rst_ni               ( rst_ni               ),
    .operands_a_i         ( operands_a_i         ),
    .operands_b_i         ( operands_b_i         ),
    .operands_a_fp6_rem_i ( operands_a_fp6_rem_i ),
    .operands_b_fp6_rem_i ( operands_b_fp6_rem_i ),
    .operands_c_i         ( operands_c_i         ),
    .operand_d_i          ( operand_d_i          ),
    .is_boxed_i           ( is_boxed_i           ),
    .rnd_mode_i           ( rnd_mode_i           ),
    .op_i                 ( op_i                 ),
    .op_mod_i             ( op_mod_i             ),
    .src_fmt_i            ( src_fmt_i            ),
    .int_fmt_i            ( int_fmt_i            ),
    .dst_fmt_i            ( dst_fmt_i            ),
    .tag_i                ( tag_i                ),
    .mask_i               ( mask_i               ),
    .aux_i                ( aux_i                ),
    .in_valid_i           ( in_valid_i           ),
    .in_ready_o           ( in_ready_o           ),
    .flush_i              ( flush_i              ),
    .result_o             ( result_o             ),
    .status_o             ( status_o             ),
    .extension_bit_o      ( extension_bit_o      ),
    .tag_o                ( tag_o                ),
    .mask_o               ( mask_o               ),
    .aux_o                ( aux_o                ),
    .out_valid_o          ( out_valid_o          ),
    .out_ready_i          ( out_ready_i          ),
    .busy_o               ( busy_o               )
  );

endmodule
