//==============================================================================
// File    : tb_pair_replay.sv
// Project : MXDOTP XIF Coprocessor - capture-and-replay output check of the
//           residue-pair synthesis wrapper (syn/wrappers/mx_syn_pair.sv)
//------------------------------------------------------------------------------
// Drives mx_syn_pair with the pair-boundary inputs captured from a system run
// (tb/scripts/vcd2stim.py, one line per rising clock edge) and compares every
// output in every cycle with the captured system outputs. Run through
// tb/scripts/pair_replay.sh.
//
//   +stim=<file>   stimulus/expected file from vcd2stim.py (required)
//   +mm=<file>     write every mismatch, one per line (optional)
//
// Per cycle k: inputs of line k are applied after the falling edge, outputs
// are compared 1 ns before the next rising edge (inputs and outputs of line k
// are the system's values just before that edge). Every cycle is compared,
// reset included. A mismatch is "valid" when the output is meaningful in that
// cycle (the control outputs always; dotp_result_id_o when the expected
// dotp_result_valid_o is 1; final_result_id/rd/data_o when the expected
// final_result_valid_o is 1) and "invalid" otherwise. Both are counted and
// reported, and both make the check FAIL.
//
// Scope: an RTL-level check of the wrapper. The xif's order-queue head gating
// of the XIF result channel (mxdotp_xif.sv:966-988, :889) is outside the pair:
// it reaches the pair only through the captured *_result_ready_i inputs, and
// neither this check nor the wrapper's synthesis covers it. The synthesised
// netlist is not checked here.
//==============================================================================
`timescale 1ns/1ps

module tb_pair_replay;

  logic        clk = 1'b1;
  logic        rst_ni;
  logic        dotp_start, dotp_result_ready, final_start, final_result_ready;
  logic [3:0]  dotp_id, final_id;
  logic [4:0]  final_rd;
  logic [63:0] dotp_rs1, dotp_rs2, dotp_rs3, final_rs1, final_rs2;

  logic        dotp_ready, dotp_result_valid, final_ready, final_result_valid;
  logic [3:0]  dotp_result_id, final_result_id;
  logic [4:0]  final_result_rd;
  logic [31:0] final_result_data;

  mx_syn_pair dut (
    .clk_i                (clk),
    .rst_ni               (rst_ni),
    .dotp_start_i         (dotp_start),
    .dotp_ready_o         (dotp_ready),
    .dotp_id_i            (dotp_id),
    .dotp_rs1_i           (dotp_rs1),
    .dotp_rs2_i           (dotp_rs2),
    .dotp_rs3_i           (dotp_rs3),
    .dotp_result_valid_o  (dotp_result_valid),
    .dotp_result_ready_i  (dotp_result_ready),
    .dotp_result_id_o     (dotp_result_id),
    .final_start_i        (final_start),
    .final_ready_o        (final_ready),
    .final_id_i           (final_id),
    .final_rd_i           (final_rd),
    .final_rs1_i          (final_rs1),
    .final_rs2_i          (final_rs2),
    .final_result_valid_o (final_result_valid),
    .final_result_ready_i (final_result_ready),
    .final_result_id_o    (final_result_id),
    .final_result_rd_o    (final_result_rd),
    .final_result_data_o  (final_result_data)
  );

  localparam int NOUT = 8;
  string port_name [NOUT] = '{"dotp_ready_o", "dotp_result_valid_o", "dotp_result_id_o", "final_ready_o",
                              "final_result_valid_o", "final_result_id_o", "final_result_rd_o",
                              "final_result_data_o"};
  int mm_valid [NOUT];
  int mm_invalid [NOUT];

  initial begin
    string stim_path, mm_path, line;
    int fd, mm_fd, n, cyc, k, shown, total_valid, total_invalid;
    logic [63:0] f [21];
    logic [31:0] exp_o [NOUT];
    logic [31:0] got_o [NOUT];
    logic        is_valid [NOUT];

    if (!$value$plusargs("stim=%s", stim_path)) $fatal(1, "tb_pair_replay: +stim=<file> is required");
    fd = $fopen(stim_path, "r");
    if (fd == 0) $fatal(1, "tb_pair_replay: cannot open %s", stim_path);
    mm_fd = 0;
    if ($value$plusargs("mm=%s", mm_path)) mm_fd = $fopen(mm_path, "w");
    for (int p = 0; p < NOUT; p++) begin mm_valid[p] = 0; mm_invalid[p] = 0; end
    k = 0; shown = 0;

    while (!$feof(fd)) begin
      line = "";
      void'($fgets(line, fd));
      if (line.len() == 0 || line[0] == "#" || line[0] == "\n") continue;
      n = $sscanf(line, "%d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                  cyc, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12],
                  f[13], f[14], f[15], f[16], f[17], f[18], f[19], f[20]);
      if (n != 22) $fatal(1, "tb_pair_replay: line %0d: %0d fields read, 22 expected", k, n);
      if (cyc != k) $fatal(1, "tb_pair_replay: line %0d carries cycle %0d", k, cyc);

      // falling edge: apply line k
      #5 clk = 1'b0;
      rst_ni             = f[0][0];
      dotp_start         = f[1][0];
      dotp_id            = f[2][3:0];
      dotp_rs1           = f[3];
      dotp_rs2           = f[4];
      dotp_rs3           = f[5];
      dotp_result_ready  = f[6][0];
      final_start        = f[7][0];
      final_id           = f[8][3:0];
      final_rd           = f[9][4:0];
      final_rs1          = f[10];
      final_rs2          = f[11];
      final_result_ready = f[12][0];

      // 1 ns before the rising edge: compare
      #4;
      got_o = '{32'(dotp_ready), 32'(dotp_result_valid), 32'(dotp_result_id), 32'(final_ready),
                32'(final_result_valid), 32'(final_result_id), 32'(final_result_rd), final_result_data};
      for (int p = 0; p < NOUT; p++) exp_o[p] = f[13 + p][31:0];
      is_valid = '{1'b1, 1'b1, exp_o[1][0], 1'b1, 1'b1, exp_o[4][0], exp_o[4][0], exp_o[4][0]};
      for (int p = 0; p < NOUT; p++) begin
        if (got_o[p] !== exp_o[p]) begin
          if (is_valid[p]) mm_valid[p]++; else mm_invalid[p]++;
          if (shown < 10) begin
            $display("MISMATCH cycle %0d %s (%s): expected %h, got %h", k, port_name[p],
                     is_valid[p] ? "valid" : "invalid", exp_o[p], got_o[p]);
            shown++;
          end
          if (mm_fd != 0) $fdisplay(mm_fd, "%0d %s %s %h %h", k, port_name[p],
                                    is_valid[p] ? "valid" : "invalid", exp_o[p], got_o[p]);
        end
      end
      #1 clk = 1'b1;
      k++;
    end
    $fclose(fd);
    if (mm_fd != 0) $fclose(mm_fd);
    if (k == 0) $fatal(1, "tb_pair_replay: %s has no data lines", stim_path);

    total_valid = 0; total_invalid = 0;
    for (int p = 0; p < NOUT; p++) begin
      total_valid += mm_valid[p]; total_invalid += mm_invalid[p];
      if (mm_valid[p] + mm_invalid[p] != 0)
        $display("  %-21s valid-cycle mismatches %0d, invalid-cycle mismatches %0d", port_name[p],
                 mm_valid[p], mm_invalid[p]);
    end
    $display("REPLAY %s: cycles %0d, valid-cycle mismatches %0d, invalid-cycle mismatches %0d",
             (total_valid + total_invalid == 0) ? "PASS" : "FAIL", k, total_valid, total_invalid);
    if (total_valid + total_invalid != 0) $fatal(1, "tb_pair_replay: FAIL");
    $finish;
  end

endmodule
