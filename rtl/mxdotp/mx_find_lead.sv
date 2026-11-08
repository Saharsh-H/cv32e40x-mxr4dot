//==============================================================================
// File    : mx_find_lead_hier.sv  (candidate - not yet the deployed module)
// Project : MXDOTP XIF Coprocessor
//------------------------------------------------------------------------------
// Description:
//   Phase B hierarchical (2-level) replacement for mx_find_lead.sv's serial
//   priority chain. Drop-in: identical port list, identical sign/mag
//   computation (copied verbatim), only the leading-one scan changes.
//
//   Structure: split the W-bit magnitude into CHUNK_W-bit chunks, zero-padded
//   on the MSB side up to a whole number of chunks (padding can never win the
//   scan and never shifts real bit positions, since real data occupies the
//   low W bits unchanged). Level 1: each chunk finds its own local leading-one
//   in parallel (cheap - CHUNK_W=8 wide, same serial-scan style as before but
//   drastically narrower). Level 2: a shallow scan over just the NCHUNKS
//   chunk-level "any-bit-set" flags picks the winning (highest-index) chunk.
//   Combine: lead_pos = winning_chunk*CHUNK_W + local_lead_within_chunk.
//
//   NCHUNKS at the four real W values: W=63->8, W=68->9, W=74->10, W=120->15.
//   Worst-case serial depth drops from up to 120 (MXFP8) down to at most
//   max(CHUNK_W, NCHUNKS) = 15 - a >7x reduction in serial chain length for
//   the widest engine, more for the narrower ones.
//
//   Correctness is established by mx_find_lead_equiv_tb.sv, an exhaustive/
//   randomized equivalence check against the original serial implementation
//   (kept as mx_find_lead_serial_ref.sv) at all four real W values, before
//   this ever replaces the deployed mx_find_lead.sv.
//==============================================================================

module mx_find_lead #(
  parameter int W = 63          // extended-word width = <FMT>_LZC_WIDTH
) (
  input  logic signed [W-1:0] word_i,
  input  logic                neg_adjust_i,
  output logic                sign_o,
  output logic signed [7:0]   lead_pos_o,   // -1 sentinel .. W-1
  output logic [W-1:0]        mag_o
);

  localparam int CHUNK_W = 8;
  localparam int NCHUNKS = (W + CHUNK_W - 1) / CHUNK_W;   // ceil(W/CHUNK_W)
  localparam int EXT_W   = NCHUNKS * CHUNK_W;
  localparam int LOCAL_W = (CHUNK_W <= 1) ? 1 : $clog2(CHUNK_W);
  localparam int CIDX_W  = (NCHUNKS <= 1) ? 1 : $clog2(NCHUNKS);

  logic         sign;
  logic [W-1:0] mag;

  logic [EXT_W-1:0]   mag_ext;
  logic [NCHUNKS-1:0]               chunk_any;
  logic [NCHUNKS-1:0][LOCAL_W-1:0] chunk_lead;

  logic               any_set;
  logic [CIDX_W-1:0]  win_chunk;
  logic [LOCAL_W-1:0] win_local;

  int ci, bi;
  logic signed [7:0] lead_pos_int;   // matches lead_pos_o's own width exactly

  always_comb begin
    // --- identical to the serial reference: sign/mag conversion ---
    sign = word_i[W-1];
    if (sign && neg_adjust_i)
      mag = ~word_i;
    else
      mag = sign ? (-word_i) : word_i;

    // Zero-extend on the MSB side only - real bit i of mag stays bit i of
    // mag_ext; the extra top bits are always 0 and can never be selected.
    mag_ext = EXT_W'(mag);

    // --- Level 1: per-chunk local leading-one (narrow serial scan) ---
    for (ci = 0; ci < NCHUNKS; ci++) begin
      chunk_any[ci]  = 1'b0;
      chunk_lead[ci] = '0;
      for (bi = CHUNK_W-1; bi >= 0; bi--) begin
        if (!chunk_any[ci] && mag_ext[ci*CHUNK_W + bi]) begin
          chunk_any[ci]  = 1'b1;
          chunk_lead[ci] = LOCAL_W'(bi);
        end
      end
    end

    // --- Level 2: shallow scan over chunk-level flags (<=15 for W=120) ---
    any_set   = 1'b0;
    win_chunk = '0;
    win_local = '0;
    for (ci = NCHUNKS-1; ci >= 0; ci--) begin
      if (!any_set && chunk_any[ci]) begin
        any_set   = 1'b1;
        win_chunk = CIDX_W'(ci);
        win_local = chunk_lead[ci];
      end
    end

    lead_pos_int = any_set
                   ? 8'(int'(win_chunk) * CHUNK_W + int'(win_local))
                   : -8'sd1;

    sign_o     = sign;
    lead_pos_o = lead_pos_int;
    mag_o      = mag;
  end

endmodule
