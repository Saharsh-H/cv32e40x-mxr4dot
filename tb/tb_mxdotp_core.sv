//==============================================================================
// File    : tb_mxdotp_core.sv
// Project : MXDOTP XIF Coprocessor - Verification Environment
//------------------------------------------------------------------------------
// Description:
//   Top-level self-checking testbench for mxdotp_core_top.sv.
//
//   Structure:
//     u_instr_rom  - instruction memory (instr_rom.sv), program lives there
//     u_data_mem   - data memory stub (data_mem_stub.sv), unused by the
//                    current program but protocol-correct if that changes
//     dut          - mxdotp_core_top.sv (cv32e40x_core + if_xif + mxdotp_xif)
//
//   Scoreboard tracks three back-to-back MXFUSED instructions (P, Q, R -
//   the fused fast path for PLAIN MX_FMT_MXFP4, see mxdotp_pkg.sv's
//   MX_SLOT_FUSED milestone header: rs1=A, rs2=B, rs3={scales,old_acc}, all
//   three 64-bit dual-read, one instruction each, writes rd directly),
//   issued with no gap between them specifically to exercise
//   mxdotp_fused_engine.sv/mxdotp_xif.sv's overlap milestone - see
//   instr_rom.sv's header for the full rationale and the exact math each
//   one checks. Checked by PHASE (all three issues, then all three
//   commits, then all three results, then all three writebacks) rather
//   than end-to-end per instruction, since that's what actually requires
//   them to be simultaneously in flight rather than merely three single-
//   instruction tests run back-to-back in the program.
//
//   Then a fourth, unrelated MX_FUNCT3_DUALREAD_TEST instruction
//   (validation-only, not part of the real MXDOTP ISA - proves the core's
//   dual-read mechanism in isolation), then an MXDOTP/MXFINAL pair
//   exercising MX_FMT_MXFP4_RESIDUAL (k=16, with residue - the only format
//   these two instructions serve any more, post-split; still exactly one
//   instruction of each kind outstanding at a time, unaffected by the
//   overlap milestone), each through:
//     Issue -> Commit -> Result -> Register file writeback
//   reading expected id/operand/destination values hierarchically from
//   u_instr_rom, so editing the program in instr_rom.sv keeps the checks in
//   sync automatically.
//
//   Note: XSim currently crashes at time 0 inside cv32e40x_alignment_buffer.sv
//   for reasons unrelated to this testbench (XSim-specific; $deposit/force
//   workarounds attempted earlier did not resolve it). This environment is
//   verified under Verilator, which does not hit the issue.
//
//==============================================================================

`timescale 1ns/1ps

module tb_mxdotp_core;

  //----------------------------------------------------------------------------
  // Clock / Reset
  //----------------------------------------------------------------------------

  localparam time         CLK_PERIOD      = 10ns;
  localparam int unsigned TIMEOUT_CYCLES  = 800;  // raised from 500 for the added Test 3 (MXFP8) program

  logic clk_i;
  logic rst_ni;

  longint unsigned mon_cycle_q;  // cycle counter of the [XIFMON] monitor (see there)

  initial clk_i = 1'b0;
  always #(CLK_PERIOD/2) clk_i = ~clk_i;

  initial begin
    rst_ni = 1'b0;
    repeat (10) @(posedge clk_i);
    rst_ni = 1'b1;
  end

  //----------------------------------------------------------------------------
  // fetch_enable_i - deliberately NOT tied directly to rst_ni. It is
  // registered so it asserts exactly one cycle after reset release, which
  // is closer to the OpenHW bring-up convention and avoids fetch_enable_i
  // being combinationally equal (bit-for-bit) to the reset net itself.
  //----------------------------------------------------------------------------

  logic fetch_enable_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) fetch_enable_q <= 1'b0;
    else         fetch_enable_q <= 1'b1;
  end

  //----------------------------------------------------------------------------
  // XSim time-0 crash workaround
  //----------------------------------------------------------------------------
  //
  // See the root-cause writeup accompanying this file for the full
  // explanation. Short version: cv32e40x_alignment_buffer.sv's rptr/wptr
  // pointer registers are X until their own always_ff reset branch runs,
  // but several continuous assigns and an always_comb block index
  // resp_q[]/valid_q[] with those pointers unconditionally (or in a `?:`
  // that evaluates both branches even under an ambiguous condition) during
  // SystemVerilog's implicit time-0 settle - before that reset branch can
  // possibly have executed. XSim faults on the resulting X-indexed array
  // read; this is not fixable by retiming clock/reset in this file, since
  // the fault occurs before any of this file's procedural code runs.
  //
  // $deposit is NOT supported by XSim (confirmed) and is not used here.
  //
  // Required run method: use xsim_workaround.tcl instead of `run -all` /
  // the "Run All" button. It forces rptr and wptr to 0 via XSim's Tcl
  // `add_force`/`remove_forces` commands (verified against UG835; XSim
  // does not have ModelSim/Questa-style `force`/`unforce`) before any
  // SystemVerilog code executes, then releases the force once the
  // design's own reset has taken over.
  //
  //   xsim tb_mxdotp_core_behav -tclbatch xsim_workaround.tcl
  //   (or, in the GUI: Tools -> Run Tcl Script -> xsim_workaround.tcl,
  //    instead of clicking "Run All")
  //
  // If you'd rather not remember to load a separate script every run, see
  // xsim_bind_workaround.sv for a self-contained alternative that applies
  // automatically whenever this testbench is elaborated.

  //----------------------------------------------------------------------------
  // Instruction memory / data memory / DUT interconnect
  //----------------------------------------------------------------------------

  logic        instr_req;
  logic        instr_gnt;
  logic        instr_rvalid;
  logic [31:0] instr_addr;
  logic [1:0]  instr_memtype;
  logic [2:0]  instr_prot;
  logic        instr_dbg;
  logic [31:0] instr_rdata;
  logic        instr_err;

  logic        data_req;
  logic        data_gnt;
  logic        data_rvalid;
  logic        data_we;
  logic [3:0]  data_be;
  logic [31:0] data_addr;
  logic [1:0]  data_memtype;
  logic [2:0]  data_prot;
  logic        data_dbg;
  logic [31:0] data_wdata;
  logic [31:0] data_rdata;
  logic        data_err;
  logic [5:0]  data_atop;
  logic        data_exokay;

  logic [63:0] mcycle;

  logic [11:0] clic_irq_id_o;
  logic        clic_irq_mode_o;
  logic        clic_irq_exit_o;

  logic        fencei_flush_req;
  logic        fencei_flush_ack;

  logic        debug_havereset;
  logic        debug_running;
  logic        debug_halted;

  logic        core_sleep;

  assign fencei_flush_ack = fencei_flush_req; // auto-ack, not exercised by this program

`ifdef MX_PROGRAM_IMAGE
  //----------------------------------------------------------------------------
  // Program-image build (make loop): one RAM serves both ports, loaded from
  // +image=<file>; see mem_model.sv. instr_rom stays instantiated but idle,
  // only because the Tests 1-6 scoreboard below reads its constants
  // hierarchically (u_instr_rom.*) and must still elaborate. The scoreboard
  // itself is not used in this build (see sb_fail and the watchdog).
  //----------------------------------------------------------------------------
  logic        img_exit_valid;
  logic [31:0] img_exit_code;
  logic        unused_rom_gnt, unused_rom_rvalid, unused_rom_err;
  logic [31:0] unused_rom_rdata;

  instr_rom u_instr_rom (
    .clk_i          ( clk_i             ),
    .rst_ni         ( rst_ni            ),
    .instr_req_i    ( 1'b0              ),
    .instr_gnt_o    ( unused_rom_gnt    ),
    .instr_rvalid_o ( unused_rom_rvalid ),
    .instr_addr_i   ( 32'h0             ),
    .instr_rdata_o  ( unused_rom_rdata  ),
    .instr_err_o    ( unused_rom_err    )
  );

  mem_model u_mem (
    .clk_i          ( clk_i          ),
    .rst_ni         ( rst_ni         ),
    .cycle_i        ( mon_cycle_q    ),
    .instr_req_i    ( instr_req      ),
    .instr_gnt_o    ( instr_gnt      ),
    .instr_rvalid_o ( instr_rvalid   ),
    .instr_addr_i   ( instr_addr     ),
    .instr_rdata_o  ( instr_rdata    ),
    .instr_err_o    ( instr_err      ),
    .data_req_i     ( data_req       ),
    .data_gnt_o     ( data_gnt       ),
    .data_rvalid_o  ( data_rvalid    ),
    .data_we_i      ( data_we        ),
    .data_be_i      ( data_be        ),
    .data_addr_i    ( data_addr      ),
    .data_wdata_i   ( data_wdata     ),
    .data_rdata_o   ( data_rdata     ),
    .data_err_o     ( data_err       ),
    .data_exokay_o  ( data_exokay    ),
    .exit_valid_o   ( img_exit_valid ),
    .exit_code_o    ( img_exit_code  )
  );
`else
  instr_rom u_instr_rom (
    .clk_i          ( clk_i        ),
    .rst_ni         ( rst_ni       ),
    .instr_req_i    ( instr_req    ),
    .instr_gnt_o    ( instr_gnt    ),
    .instr_rvalid_o ( instr_rvalid ),
    .instr_addr_i   ( instr_addr   ),
    .instr_rdata_o  ( instr_rdata  ),
    .instr_err_o    ( instr_err    )
  );

  data_mem_stub u_data_mem (
    .clk_i         ( clk_i       ),
    .rst_ni        ( rst_ni      ),
    .data_req_i    ( data_req    ),
    .data_gnt_o    ( data_gnt    ),
    .data_rvalid_o ( data_rvalid ),
    .data_we_i     ( data_we     ),
    .data_be_i     ( data_be     ),
    .data_addr_i   ( data_addr   ),
    .data_wdata_i  ( data_wdata  ),
    .data_rdata_o  ( data_rdata  ),
    .data_err_o    ( data_err    ),
    .data_exokay_o ( data_exokay )
  );
`endif

  mxdotp_core_top dut (
    .clk_i                 ( clk_i               ),
    .rst_ni                ( rst_ni              ),
    .scan_cg_en_i           ( 1'b0                ),

    .boot_addr_i            ( 32'h0000_0000       ),
    .mtvec_addr_i           ( 32'h0000_0000       ),
    .dm_halt_addr_i         ( 32'h0000_0000       ),
    .mhartid_i              ( 32'h0000_0000       ),
    .mimpid_i               ( 32'h0000_0000       ),
    .dm_exception_addr_i    ( 32'h0000_0000       ),
    .nmi_addr_i             ( 32'h0000_0000       ),

    .instr_req_o            ( instr_req           ),
    .instr_gnt_i            ( instr_gnt           ),
    .instr_rvalid_i         ( instr_rvalid        ),
    .instr_addr_o           ( instr_addr          ),
    .instr_memtype_o        ( instr_memtype       ),
    .instr_prot_o           ( instr_prot          ),
    .instr_dbg_o            ( instr_dbg           ),
    .instr_rdata_i          ( instr_rdata         ),
    .instr_err_i            ( instr_err           ),

    .data_req_o             ( data_req            ),
    .data_gnt_i             ( data_gnt            ),
    .data_rvalid_i          ( data_rvalid         ),
    .data_we_o              ( data_we             ),
    .data_be_o              ( data_be             ),
    .data_addr_o            ( data_addr           ),
    .data_memtype_o         ( data_memtype        ),
    .data_prot_o            ( data_prot           ),
    .data_dbg_o             ( data_dbg            ),
    .data_wdata_o           ( data_wdata          ),
    .data_rdata_i           ( data_rdata          ),
    .data_err_i             ( data_err            ),
    .data_atop_o            ( data_atop           ),
    .data_exokay_i          ( data_exokay         ),

    .mcycle_o               ( mcycle              ),

    .irq_i                  ( 32'h0               ),
    .clic_irq_i             ( 1'b0                ),
    .clic_irq_id_i          ( 12'h0               ),
    .clic_irq_il_i          ( 8'h0                ),
    .clic_irq_priv_i        ( 2'h0                ),
    .clic_irq_hv_i          ( 1'b0                ),
    .clic_irq_id_o          ( clic_irq_id_o       ),
    .clic_irq_mode_o        ( clic_irq_mode_o     ),
    .clic_irq_exit_o        ( clic_irq_exit_o     ),

    .fencei_flush_req_o     ( fencei_flush_req    ),
    .fencei_flush_ack_i     ( fencei_flush_ack    ),

    .debug_req_i            ( 1'b0                ),
    .debug_havereset_o      ( debug_havereset     ),
    .debug_running_o        ( debug_running       ),
    .debug_halted_o         ( debug_halted        ),

    .fetch_enable_i         ( fetch_enable_q      ),
    .core_sleep_o           ( core_sleep          )
  );

  //----------------------------------------------------------------------------
  // XIF observation - hierarchical taps onto the interface instance and the
  // core's internal writeback signals inside mxdotp_core_top.sv
  //----------------------------------------------------------------------------

  wire        xif_issue_valid  = dut.xif.issue_valid;
  wire        xif_issue_ready  = dut.xif.issue_ready;
  wire        xif_issue_accept = dut.xif.issue_resp.accept;
  wire        xif_issue_wb     = dut.xif.issue_resp.writeback;
  wire        xif_issue_dr     = dut.xif.issue_resp.dualread;
  wire [31:0] xif_issue_instr  = dut.xif.issue_req.instr;
  wire [3:0]  xif_issue_id     = dut.xif.issue_req.id;
  // Truncating 64-bit taps (X_RFR_WIDTH is now 64 - see mxdotp_core_top.sv): fine for
  // MXDOTP/MXFINAL, which never set dualread and so only ever have meaningful data in the
  // low 32 bits. The full 64-bit rs[0] is tapped separately below for the dualread test,
  // which does care about the upper half.
  wire [31:0] xif_issue_rs0    = dut.xif.issue_req.rs[0];
  wire [31:0] xif_issue_rs1    = dut.xif.issue_req.rs[1];
  wire [31:0] xif_issue_rs2    = dut.xif.issue_req.rs[2];
  wire [63:0] xif_issue_rs0_wide = dut.xif.issue_req.rs[0];
  wire [63:0] xif_issue_rs1_wide = dut.xif.issue_req.rs[1];
  wire [63:0] xif_issue_rs2_wide = dut.xif.issue_req.rs[2];

  wire        xif_commit_valid = dut.xif.commit_valid;
  wire [3:0]  xif_commit_id    = dut.xif.commit.id;
  wire        xif_commit_kill  = dut.xif.commit.commit_kill;

  wire        xif_result_valid = dut.xif.result_valid;
  wire        xif_result_ready = dut.xif.result_ready;
  wire [3:0]  xif_result_id    = dut.xif.result.id;
  wire [4:0]  xif_result_rd    = dut.xif.result.rd;
  wire [31:0] xif_result_data  = dut.xif.result.data;
  wire        xif_result_we    = dut.xif.result.we;

  wire        rf_we_wb_o    = dut.core_i.rf_we_wb;
  wire [4:0]  rf_waddr_wb_o = dut.core_i.rf_waddr_wb;
  wire [31:0] rf_wdata_wb_o = dut.core_i.rf_wdata_wb;

  // Expected values for Test 1 (MXFUSED x3 back-to-back, P/Q/R, MX_FMT_MXFP4)
  // under test, read hierarchically from instr_rom.sv - edit the program
  // there, not here. A/B/rs3 (={scales,old_acc}) are all 64-bit dual-read -
  // see mxdotp_pkg.sv's MX_SLOT_FUSED milestone header. There is no AR
  // operand in this instruction's encoding at all any more.
  //
  // Three separate instructions now, not one - see instr_rom.sv's header
  // for why: this is the overlap milestone's own test, specifically built
  // so P/Q/R are simultaneously at different stages of
  // mxdotp_fused_engine.sv's pipeline, not just three sequential single-
  // instruction runs.
  wire [31:0] exp_fused_instr = u_instr_rom.INSTR_MXFUSED;
  wire [63:0] exp_fa_val      = u_instr_rom.A_VAL;
  wire [63:0] exp_fb_val      = u_instr_rom.B_VAL;
  wire [63:0] exp_frs3_val    = u_instr_rom.FRS3_VAL;
  wire [4:0]  exp_fused_rd    = u_instr_rom.REG_FRESULT;
  wire [31:0] exp_fused_data  = u_instr_rom.MXFP4_FUSED_EXPECTED;

  wire [31:0] exp_fused_q_instr = u_instr_rom.INSTR_MXFUSED_Q;
  wire [63:0] exp_qa_val        = u_instr_rom.QA_VAL;
  wire [63:0] exp_qb_val        = u_instr_rom.QB_VAL;
  wire [63:0] exp_frs3_q_val    = u_instr_rom.FRS3_VAL;  // Q reuses P's rs3 registers - same value
  wire [4:0]  exp_fused_q_rd    = u_instr_rom.REG_QRESULT;
  wire [31:0] exp_fused_q_data  = u_instr_rom.MXFP4_FUSED_Q_EXPECTED;

  wire [31:0] exp_fused_r_instr = u_instr_rom.INSTR_MXFUSED_R;
  wire [63:0] exp_ra_val_ovl    = u_instr_rom.A_VAL;   // R reuses P's A registers - same value
                                                         // (named _ovl to avoid clashing with the
                                                         // residual test's own exp_ra_val below)
  wire [63:0] exp_rb_val_ovl    = u_instr_rom.QB_VAL;  // R reuses Q's B registers - same value
  wire [63:0] exp_rrs3_val      = u_instr_rom.RRS3_VAL;
  wire [4:0]  exp_fused_r_rd    = u_instr_rom.REG_RRESULT;
  wire [31:0] exp_fused_r_data  = u_instr_rom.MXFP4_FUSED_R_EXPECTED;

  // Dual-read validation test (MX_FUNCT3_DUALREAD_TEST) expected values - see
  // instr_rom.sv header for the full rationale.
  wire [31:0] exp_dualread_instr = u_instr_rom.INSTR_MXDUALREAD_TEST;
  wire [4:0]  exp_dualread_rd    = u_instr_rom.REG_DR_RESULT;
  wire [31:0] exp_dualread_lo    = u_instr_rom.DUALREAD_LO_VAL;
  wire [31:0] exp_dualread_hi    = u_instr_rom.DUALREAD_HI_VAL;
  wire [31:0] exp_dualread_data  = u_instr_rom.DUALREAD_EXPECTED;

  // MX_FMT_MXFP4_RESIDUAL (k=16, with residue) expected values - see
  // instr_rom.sv header for the full derivation. MXFINAL(residual)'s
  // scales/old_acc are now two SEPARATE plain 32-bit operands (rs1/rs2),
  // not one combined 64-bit dual-read pair - see mxdotp_pkg.sv's milestone
  // header for why that changed.
  wire [31:0] exp_rdotp_instr  = u_instr_rom.INSTR_MXDOTP_RESIDUAL;
  wire [63:0] exp_ra_val       = u_instr_rom.RA_VAL;
  wire [63:0] exp_rb_val       = u_instr_rom.RB_VAL;
  wire [63:0] exp_rar_val      = u_instr_rom.RAR_VAL;

  wire [31:0] exp_rfinal_instr = u_instr_rom.INSTR_MXFINAL_RESIDUAL;
  wire [4:0]  exp_rfinal_rd    = u_instr_rom.REG_RRESULT_FINAL;  // renamed in instr_rom.sv to
                                                                    // avoid clashing with Test 1's
                                                                    // own REG_RRESULT (R's rd)
  wire [31:0] exp_rscales      = u_instr_rom.RSCALES_VAL;
  wire [31:0] exp_rold_acc     = u_instr_rom.ROLD_ACC_VAL;
  wire [31:0] exp_rfinal_data  = u_instr_rom.MXFP4_RESIDUAL_EXPECTED;

  // Test 3: MXFP8 (E4M3 S / E5M2 T) + MXFP4 (M), cross-engine overlap.
  wire [4:0]  exp_f8s_rd    = u_instr_rom.REG_F8S_RESULT;   // x7
  wire [31:0] exp_f8s_data  = u_instr_rom.MXFP8_S_EXPECTED;  // 10.5
  wire [4:0]  exp_f4m_rd    = u_instr_rom.REG_F4M_RESULT;   // x8
  wire [31:0] exp_f4m_data  = u_instr_rom.MXFP4_M_EXPECTED;  // 16.0
  wire [4:0]  exp_f8t_rd    = u_instr_rom.REG_F8T_RESULT;   // x26
  wire [31:0] exp_f8t_data  = u_instr_rom.MXFP8_T_EXPECTED;  // 8.0

  // Test 4: M2XFP4 (U) + three-engine overlap (U/V/W). Destinations are
  // pristine registers - see instr_rom.sv's Test 4 header for why that is a
  // requirement of the first-write-wins capture latches below, not a
  // preference.
  wire [4:0]  exp_m2u_rd    = u_instr_rom.REG_M2U_RESULT;    // x27
  wire [31:0] exp_m2u_data  = u_instr_rom.M2XFP4_U_EXPECTED; // 29.875
  wire [4:0]  exp_m2v_rd    = u_instr_rom.REG_M2V_RESULT;    // x19
  wire [31:0] exp_m2v_data  = u_instr_rom.MXFP4_V_EXPECTED;  // 16.0
  wire [4:0]  exp_m2w_rd    = u_instr_rom.REG_M2W_RESULT;    // x20
  wire [31:0] exp_m2w_data  = u_instr_rom.MXFP8_W_EXPECTED;  // 8.0

  // Test 5: MXDOTP/MXFINAL mailbox robustness + 2nd numeric residue case (see
  // instr_rom.sv's Test 5 header). Destinations REUSE x9 (fused) and x21
  // (final); the ARMED writeback latches below capture Test 5's own writes,
  // not the earlier first-write-wins ones.
  wire [4:0]  exp_t5_fused_rd    = u_instr_rom.REG_T5_FUSED_RESULT;      // x9
  wire [31:0] exp_t5_fused_data  = u_instr_rom.T5_FUSED_EXPECTED;        // 32.0
  wire [4:0]  exp_t5_rfinal_rd   = u_instr_rom.REG_T5_RFINAL_RESULT;     // x21
  wire [31:0] exp_t5_rfinal_data = u_instr_rom.MXFP4_RESIDUAL2_EXPECTED; // 84.0

  //----------------------------------------------------------------------------
  // Protocol assertion: once result_valid is asserted without being accepted
  // the same cycle, it must remain asserted until result_ready arrives.
  //----------------------------------------------------------------------------

  property p_result_valid_stable;
    @(posedge clk_i) disable iff (!rst_ni)
    (xif_result_valid && !xif_result_ready) |=> xif_result_valid;
  endproperty

  assert property (p_result_valid_stable)
    else $error("[%0t] PROTOCOL VIOLATION: result_valid dropped before result_ready", $time);

  //----------------------------------------------------------------------------
  // Scoreboard: tracks one MXDOTP instruction through
  // Issue -> Commit -> Result -> Register file writeback
  //----------------------------------------------------------------------------

  typedef enum logic [5:0] {
    SB_WAIT_P_ISSUE,
    SB_WAIT_Q_ISSUE,
    SB_WAIT_R_ISSUE,
    SB_WAIT_P_COMMIT,
    SB_WAIT_Q_COMMIT,
    SB_WAIT_R_COMMIT,
    SB_WAIT_P_RESULT,
    SB_WAIT_Q_RESULT,
    SB_WAIT_R_RESULT,
    SB_WAIT_P_WB,
    SB_WAIT_Q_WB,
    SB_WAIT_R_WB,
    SB_WAIT_DUALREAD_ISSUE,
    SB_WAIT_DUALREAD_COMMIT,
    SB_WAIT_DUALREAD_RESULT,
    SB_WAIT_DUALREAD_WB,
    SB_WAIT_RDOTP_ISSUE,
    SB_WAIT_RDOTP_COMMIT,
    SB_WAIT_RDOTP_RESULT,
    SB_WAIT_RFINAL_ISSUE,
    SB_WAIT_RFINAL_COMMIT,
    SB_WAIT_RFINAL_RESULT,
    SB_WAIT_RFINAL_WB,
    SB_WAIT_F8S_WB,
    SB_WAIT_F8M_WB,
    SB_WAIT_F8T_WB,
    SB_WAIT_M2U_WB,
    SB_WAIT_M2V_WB,
    SB_WAIT_M2W_WB,
    SB_WAIT_T5_FUSED_WB,
    SB_WAIT_T5_RFINAL_WB,
    SB_WAIT_T6_PAIRS,
    SB_DONE,
    SB_FAIL
  } sb_state_e;

  sb_state_e   sb_state;

  int unsigned pass_count;
  int unsigned fail_count;

  // Failure flag for this cycle (set combinationally, consumed by always_ff)
  logic        sb_fail_this_cycle;
  string       sb_fail_msg;

  initial begin
    sb_state            = SB_WAIT_P_ISSUE;
    pass_count          = 0;
    fail_count          = 0;
    sb_fail_this_cycle  = 1'b0;
    sb_fail_msg         = "";
  end

  //----------------------------------------------------------------------------
  // P/Q/R (Test 1's overlap sequence) issue/commit/result capture -
  // independent of sb_state, for exactly the same reason the RF writeback
  // capture just below is independent of sb_state (see that section's own
  // header, written for an entirely different race but describing the
  // identical underlying problem).
  //
  // The first real overlap run exposed this precisely: P/Q/R issued
  // correctly back-to-back (385000/395000/405000), but the scoreboard's
  // first observed commit carried id=2 (R's) - P's and Q's own commits had
  // already fired, unseen, while the scoreboard was still sequentially
  // watching for ISSUE events, not COMMIT events. xif_commit_valid (and
  // xif_result_valid) are transient, one-shot pulses on the XIF bus, same
  // as rf_we_wb_o below - a scoreboard state that only watches for one
  // while parked in a DIFFERENT state will silently miss it, and with true
  // overlap, commits and results can legitimately arrive while the
  // scoreboard is still processing an earlier phase (unlike the fully
  // sequential single-instruction tests elsewhere in this file, where nothing
  // else is happening concurrently to race against).
  //
  // Issue capture is matched by INSTRUCTION WORD (P/Q/R's are distinct),
  // continuously, per instruction - safe because a single-issue in-order
  // core cannot present them out of program order regardless of timing.
  //
  // Commit and result capture are POSITIONAL instead (the 1st/2nd/3rd
  // commit_valid, or result_valid&&result_ready, pulse observed anywhere in
  // the program) - deliberately NOT id-matched like issue: matching by id
  // would make it impossible to ever notice if the DUT delivered them out
  // of order, since each id-matched latch would just fire whenever its own
  // id eventually appeared, however late. Positional capture, cross-checked
  // against each instruction's own issue-captured id in the polling states
  // further down, is what keeps the "commits/results must arrive in P,Q,R
  // program order" property actually checked, not just assumed. Capture
  // stops after 3 (idx==3) - later tests in this program use the ordinary
  // live single-instruction watching pattern in their own untouched states,
  // unaffected by this.
  //----------------------------------------------------------------------------

  logic        p_issue_seen_q, q_issue_seen_q, r_issue_seen_q;
  logic [3:0]  p_issue_id_q,   q_issue_id_q,   r_issue_id_q;
  logic [63:0] p_issue_a_q,    q_issue_a_q,    r_issue_a_q;
  logic [63:0] p_issue_b_q,    q_issue_b_q,    r_issue_b_q;
  logic [63:0] p_issue_rs3_q,  q_issue_rs3_q,  r_issue_rs3_q;
  logic        p_issue_accept_q, q_issue_accept_q, r_issue_accept_q;
  logic        p_issue_wb_q,     q_issue_wb_q,     r_issue_wb_q;
  logic        p_issue_dr_q,     q_issue_dr_q,     r_issue_dr_q;
  time         p_issue_time_q,   q_issue_time_q,   r_issue_time_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      p_issue_seen_q <= 1'b0; q_issue_seen_q <= 1'b0; r_issue_seen_q <= 1'b0;
      p_issue_id_q <= '0; q_issue_id_q <= '0; r_issue_id_q <= '0;
      p_issue_a_q <= '0; q_issue_a_q <= '0; r_issue_a_q <= '0;
      p_issue_b_q <= '0; q_issue_b_q <= '0; r_issue_b_q <= '0;
      p_issue_rs3_q <= '0; q_issue_rs3_q <= '0; r_issue_rs3_q <= '0;
      p_issue_accept_q <= 1'b0; q_issue_accept_q <= 1'b0; r_issue_accept_q <= 1'b0;
      p_issue_wb_q <= 1'b0; q_issue_wb_q <= 1'b0; r_issue_wb_q <= 1'b0;
      p_issue_dr_q <= 1'b0; q_issue_dr_q <= 1'b0; r_issue_dr_q <= 1'b0;
      p_issue_time_q <= '0; q_issue_time_q <= '0; r_issue_time_q <= '0;
    end else begin
      if (!p_issue_seen_q && xif_issue_valid && xif_issue_ready && (xif_issue_instr == exp_fused_instr)) begin
        p_issue_seen_q   <= 1'b1;
        p_issue_id_q     <= xif_issue_id;
        p_issue_a_q      <= xif_issue_rs0_wide;
        p_issue_b_q      <= xif_issue_rs1_wide;
        p_issue_rs3_q    <= xif_issue_rs2_wide;
        p_issue_accept_q <= xif_issue_accept;
        p_issue_wb_q     <= xif_issue_wb;
        p_issue_dr_q     <= xif_issue_dr;
        p_issue_time_q   <= $time;
      end
      if (!q_issue_seen_q && xif_issue_valid && xif_issue_ready && (xif_issue_instr == exp_fused_q_instr)) begin
        q_issue_seen_q   <= 1'b1;
        q_issue_id_q     <= xif_issue_id;
        q_issue_a_q      <= xif_issue_rs0_wide;
        q_issue_b_q      <= xif_issue_rs1_wide;
        q_issue_rs3_q    <= xif_issue_rs2_wide;
        q_issue_accept_q <= xif_issue_accept;
        q_issue_wb_q     <= xif_issue_wb;
        q_issue_dr_q     <= xif_issue_dr;
        q_issue_time_q   <= $time;
      end
      if (!r_issue_seen_q && xif_issue_valid && xif_issue_ready && (xif_issue_instr == exp_fused_r_instr)) begin
        r_issue_seen_q   <= 1'b1;
        r_issue_id_q     <= xif_issue_id;
        r_issue_a_q      <= xif_issue_rs0_wide;
        r_issue_b_q      <= xif_issue_rs1_wide;
        r_issue_rs3_q    <= xif_issue_rs2_wide;
        r_issue_accept_q <= xif_issue_accept;
        r_issue_wb_q     <= xif_issue_wb;
        r_issue_dr_q     <= xif_issue_dr;
        r_issue_time_q   <= $time;
      end
    end
  end

  // Depth 6: P, Q, R, DUALREAD_TEST, RDOTP, RFINAL - every offloaded
  // instruction in the program, not just the three FUSED ones. Originally
  // this stopped at 3, with the downstream tests still watching live
  // signals from their own states - but the overlap run showed the DUT
  // free-runs far ahead of this scoreboard (which burns one cycle per
  // polling state), so the DUALREAD/RDOTP/RFINAL pulses can also fire
  // while the scoreboard is still chewing through earlier phases. Same
  // missed-pulse race, same fix: capture everything continuously,
  // positionally, and let the states poll at their own pace.
  localparam int SB_NUM_OFFLOADS = 6;
  logic [2:0] commit_capture_idx_q;  // 0..6; saturates at SB_NUM_OFFLOADS
  logic [3:0] commit_capture_id_q   [0:SB_NUM_OFFLOADS-1];
  logic       commit_capture_kill_q [0:SB_NUM_OFFLOADS-1];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      commit_capture_idx_q <= 3'd0;
      for (int ci = 0; ci < SB_NUM_OFFLOADS; ci++) begin
        commit_capture_id_q[ci]   <= '0;
        commit_capture_kill_q[ci] <= 1'b0;
      end
    end else if ((commit_capture_idx_q < 3'(SB_NUM_OFFLOADS)) && xif_commit_valid) begin
      commit_capture_id_q[commit_capture_idx_q]   <= xif_commit_id;
      commit_capture_kill_q[commit_capture_idx_q] <= xif_commit_kill;
      commit_capture_idx_q <= commit_capture_idx_q + 3'd1;
    end
  end

  logic [2:0]  result_capture_idx_q;  // 0..6; saturates at SB_NUM_OFFLOADS
  logic [3:0]  result_capture_id_q   [0:SB_NUM_OFFLOADS-1];
  logic [4:0]  result_capture_rd_q   [0:SB_NUM_OFFLOADS-1];
  logic [31:0] result_capture_data_q [0:SB_NUM_OFFLOADS-1];
  logic        result_capture_we_q   [0:SB_NUM_OFFLOADS-1];
  time         result_capture_time_q [0:SB_NUM_OFFLOADS-1];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      result_capture_idx_q <= 3'd0;
      for (int ri = 0; ri < SB_NUM_OFFLOADS; ri++) begin
        result_capture_id_q[ri]   <= '0;
        result_capture_rd_q[ri]   <= '0;
        result_capture_data_q[ri] <= '0;
        result_capture_we_q[ri]   <= 1'b0;
        result_capture_time_q[ri] <= '0;
      end
    end else if ((result_capture_idx_q < 3'(SB_NUM_OFFLOADS)) && xif_result_valid && xif_result_ready) begin
      result_capture_id_q[result_capture_idx_q]   <= xif_result_id;
      result_capture_rd_q[result_capture_idx_q]   <= xif_result_rd;
      result_capture_data_q[result_capture_idx_q] <= xif_result_data;
      result_capture_we_q[result_capture_idx_q]   <= xif_result_we;
      result_capture_time_q[result_capture_idx_q] <= $time;
      result_capture_idx_q <= result_capture_idx_q + 3'd1;
    end
  end

  // Issue captures for the three downstream tests - same instruction-word-
  // matched, always-on pattern as P/Q/R's above, and needed for exactly the
  // same reason (see the depth-6 comment on the commit capture above).
  logic        dr_issue_seen_q, rdotp_issue_seen_q, rfinal_issue_seen_q;
  logic [3:0]  dr_issue_id_q,   rdotp_issue_id_q,   rfinal_issue_id_q;
  logic [63:0] dr_issue_rs1w_q;
  logic [63:0] rdotp_issue_a_q, rdotp_issue_b_q, rdotp_issue_ar_q;
  logic [31:0] rfinal_issue_scales_q, rfinal_issue_oldacc_q;
  logic        dr_issue_accept_q, rdotp_issue_accept_q, rfinal_issue_accept_q;
  logic        dr_issue_wb_q,     rdotp_issue_wb_q,     rfinal_issue_wb_q;
  logic        dr_issue_dr_q,     rdotp_issue_dr_q,     rfinal_issue_dr_q;
  time         dr_issue_time_q,   rdotp_issue_time_q,   rfinal_issue_time_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dr_issue_seen_q <= 1'b0; rdotp_issue_seen_q <= 1'b0; rfinal_issue_seen_q <= 1'b0;
      dr_issue_id_q <= '0; rdotp_issue_id_q <= '0; rfinal_issue_id_q <= '0;
      dr_issue_rs1w_q <= '0;
      rdotp_issue_a_q <= '0; rdotp_issue_b_q <= '0; rdotp_issue_ar_q <= '0;
      rfinal_issue_scales_q <= '0; rfinal_issue_oldacc_q <= '0;
      dr_issue_accept_q <= 1'b0; rdotp_issue_accept_q <= 1'b0; rfinal_issue_accept_q <= 1'b0;
      dr_issue_wb_q <= 1'b0; rdotp_issue_wb_q <= 1'b0; rfinal_issue_wb_q <= 1'b0;
      dr_issue_dr_q <= 1'b0; rdotp_issue_dr_q <= 1'b0; rfinal_issue_dr_q <= 1'b0;
      dr_issue_time_q <= '0; rdotp_issue_time_q <= '0; rfinal_issue_time_q <= '0;
    end else begin
      if (!dr_issue_seen_q && xif_issue_valid && xif_issue_ready && (xif_issue_instr == exp_dualread_instr)) begin
        dr_issue_seen_q   <= 1'b1;
        dr_issue_id_q     <= xif_issue_id;
        dr_issue_rs1w_q   <= xif_issue_rs0_wide;
        dr_issue_accept_q <= xif_issue_accept;
        dr_issue_wb_q     <= xif_issue_wb;
        dr_issue_dr_q     <= xif_issue_dr;
        dr_issue_time_q   <= $time;
      end
      if (!rdotp_issue_seen_q && xif_issue_valid && xif_issue_ready && (xif_issue_instr == exp_rdotp_instr)) begin
        rdotp_issue_seen_q   <= 1'b1;
        rdotp_issue_id_q     <= xif_issue_id;
        rdotp_issue_a_q      <= xif_issue_rs0_wide;
        rdotp_issue_b_q      <= xif_issue_rs1_wide;
        rdotp_issue_ar_q     <= xif_issue_rs2_wide;
        rdotp_issue_accept_q <= xif_issue_accept;
        rdotp_issue_wb_q     <= xif_issue_wb;
        rdotp_issue_dr_q     <= xif_issue_dr;
        rdotp_issue_time_q   <= $time;
      end
      if (!rfinal_issue_seen_q && xif_issue_valid && xif_issue_ready && (xif_issue_instr == exp_rfinal_instr)) begin
        rfinal_issue_seen_q   <= 1'b1;
        rfinal_issue_id_q     <= xif_issue_id;
        rfinal_issue_scales_q <= xif_issue_rs0;
        rfinal_issue_oldacc_q <= xif_issue_rs1;
        rfinal_issue_accept_q <= xif_issue_accept;
        rfinal_issue_wb_q     <= xif_issue_wb;
        rfinal_issue_dr_q     <= xif_issue_dr;
        rfinal_issue_time_q   <= $time;
      end
    end
  end

  //----------------------------------------------------------------------------
  // RF writeback capture - independent of sb_state.
  //
  // CV32E40X retires an accepted XIF result into the register file
  // *combinationally in the same cycle* result_valid && result_ready fires
  // (rf_we_wb/rf_waddr_wb/rf_wdata_wb are driven straight from the accepted
  // result in the WB stage, not registered a cycle later). The main
  // scoreboard below is a single always_ff/case block that only evaluates
  // one state's body per clock edge, so the SB_WAIT_RESULT -> SB_WAIT_WB
  // transition (triggered this same cycle) can't also check the WB
  // condition on that same cycle - by the time sb_state actually becomes
  // SB_WAIT_WB (the following cycle), the one-shot rf_we_wb_o pulse for x5
  // has already come and gone (the next instruction to retire, e.g. the
  // JAL_SELF's x0 write, has taken its place). That race - not a bug in
  // mxdotp_xif.sv/mxdotp_execute.sv - is what was causing the SB_WAIT_WB
  // timeout: this test's own scoreboard was arriving one cycle too late to
  // see an event it should have caught the very cycle RESULT fired.
  //
  // Fix: capture the write the instant it happens, in its own always_ff,
  // independent of sb_state. SB_WAIT_WB then reads this latch instead of
  // sampling the live (possibly already-passed) pulse directly.
  //----------------------------------------------------------------------------

  logic        wb_seen_q;
  logic [31:0] wb_data_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen_q <= 1'b0;
      wb_data_q <= '0;
    end else if (!wb_seen_q && rf_we_wb_o && (rf_waddr_wb_o == exp_fused_rd)) begin
      wb_seen_q <= 1'b1;
      wb_data_q <= rf_wdata_wb_o;
    end
  end

  // Second, independent instance of the exact same latch pattern above, watching for the
  // dual-read test instruction's destination register instead of MXFINAL's. Deliberately a
  // separate signal pair rather than reusing wb_seen_q/wb_data_q for a second purpose: the
  // whole reason that latch exists is to decouple each capture from the scoreboard's own
  // state and from every other capture, so aliasing two different instructions' writebacks
  // onto one latch would just reintroduce a version of the same race this pattern was
  // built to avoid.
  logic        wb_seen2_q;
  logic [31:0] wb_data2_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen2_q <= 1'b0;
      wb_data2_q <= '0;
    end else if (!wb_seen2_q && rf_we_wb_o && (rf_waddr_wb_o == exp_dualread_rd)) begin
      wb_seen2_q <= 1'b1;
      wb_data2_q <= rf_wdata_wb_o;
    end
  end

  // Third instance of the same latch pattern, for the residual-mode test's destination
  // register - same rationale as wb_seen2_q above: a dedicated, decoupled capture per
  // instruction under test, not a shared/reused one.
  logic        wb_seen3_q;
  logic [31:0] wb_data3_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen3_q <= 1'b0;
      wb_data3_q <= '0;
    end else if (!wb_seen3_q && rf_we_wb_o && (rf_waddr_wb_o == exp_rfinal_rd)) begin
      wb_seen3_q <= 1'b1;
      wb_data3_q <= rf_wdata_wb_o;
    end
  end

  // Fourth and fifth instances of the same latch pattern, for Q's and R's destination
  // registers (Test 1's back-to-back MXFUSED overlap test - see instr_rom.sv header).
  // Same rationale as wb_seen2_q/wb_seen3_q above, and doubly important here: P/Q/R can
  // be simultaneously in flight, so each one's writeback genuinely needs its own
  // independent, decoupled capture - reusing one latch across overlapping instructions
  // would be exactly the aliasing hazard this pattern exists to avoid.
  logic        wb_seen4_q;
  logic [31:0] wb_data4_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen4_q <= 1'b0;
      wb_data4_q <= '0;
    end else if (!wb_seen4_q && rf_we_wb_o && (rf_waddr_wb_o == exp_fused_q_rd)) begin
      wb_seen4_q <= 1'b1;
      wb_data4_q <= rf_wdata_wb_o;
    end
  end

  logic        wb_seen5_q;
  logic [31:0] wb_data5_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen5_q <= 1'b0;
      wb_data5_q <= '0;
    end else if (!wb_seen5_q && rf_we_wb_o && (rf_waddr_wb_o == exp_fused_r_rd)) begin
      wb_seen5_q <= 1'b1;
      wb_data5_q <= rf_wdata_wb_o;
    end
  end

  // Sixth/seventh/eighth latch instances - Test 3's S (MXFP8 E4M3), M (MXFP4)
  // and T (MXFP8 E5M2) destinations. Same decoupled-per-instruction rationale
  // as the P/Q/R latches above; S/M/T can be simultaneously in flight across
  // the two fused engines, so each needs its own independent capture.
  logic        wb_seen6_q;  logic [31:0] wb_data6_q;
  logic        wb_seen7_q;  logic [31:0] wb_data7_q;
  logic        wb_seen8_q;  logic [31:0] wb_data8_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen6_q <= 1'b0; wb_data6_q <= '0;
    end else if (!wb_seen6_q && rf_we_wb_o && (rf_waddr_wb_o == exp_f8s_rd)) begin
      wb_seen6_q <= 1'b1; wb_data6_q <= rf_wdata_wb_o;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen7_q <= 1'b0; wb_data7_q <= '0;
    end else if (!wb_seen7_q && rf_we_wb_o && (rf_waddr_wb_o == exp_f4m_rd)) begin
      wb_seen7_q <= 1'b1; wb_data7_q <= rf_wdata_wb_o;
    end
  end
  // Ninth/tenth/eleventh latch instances - Test 4's U (M2XFP4), V (MXFP4) and
  // W (MXFP8 E4M3) destinations. Same decoupled-per-instruction rationale as
  // every latch above, and it applies with full force here: U/V/W are in
  // flight across all THREE fused engines at once, so each needs its own
  // independent capture.
  logic        wb_seen9_q;   logic [31:0] wb_data9_q;
  logic        wb_seen10_q;  logic [31:0] wb_data10_q;
  logic        wb_seen11_q;  logic [31:0] wb_data11_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen9_q <= 1'b0; wb_data9_q <= '0;
    end else if (!wb_seen9_q && rf_we_wb_o && (rf_waddr_wb_o == exp_m2u_rd)) begin
      wb_seen9_q <= 1'b1; wb_data9_q <= rf_wdata_wb_o;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen10_q <= 1'b0; wb_data10_q <= '0;
    end else if (!wb_seen10_q && rf_we_wb_o && (rf_waddr_wb_o == exp_m2v_rd)) begin
      wb_seen10_q <= 1'b1; wb_data10_q <= rf_wdata_wb_o;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen11_q <= 1'b0; wb_data11_q <= '0;
    end else if (!wb_seen11_q && rf_we_wb_o && (rf_waddr_wb_o == exp_m2w_rd)) begin
      wb_seen11_q <= 1'b1; wb_data11_q <= rf_wdata_wb_o;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen8_q <= 1'b0; wb_data8_q <= '0;
    end else if (!wb_seen8_q && rf_we_wb_o && (rf_waddr_wb_o == exp_f8t_rd)) begin
      wb_seen8_q <= 1'b1; wb_data8_q <= rf_wdata_wb_o;
    end
  end

  //----------------------------------------------------------------------------
  // Cross-engine ordering monitor (Test 3). S/M/T issue back-to-back in that
  // program order but run on two different engines (S,T -> fp8; M -> fp4)
  // concurrently. The two-slot order queue must still retire their writebacks
  // in program order: S (x7), then M (x8), then T (x26). Because those three
  // destination registers are written ONLY by S/M/T (no load targets them),
  // watching every rf_we_wb_o to one of them yields exactly the delivery
  // sequence - any out-of-order retirement sets f8_ord_bad, checked at the end.
  //----------------------------------------------------------------------------
  typedef enum logic [1:0] { F8ORD_S, F8ORD_M, F8ORD_T, F8ORD_DONE } f8_ord_e;
  f8_ord_e f8_ord_q;
  logic    f8_ord_bad;

  wire f8_wb_hit = rf_we_wb_o && ((rf_waddr_wb_o == exp_f8s_rd) ||
                                  (rf_waddr_wb_o == exp_f4m_rd) ||
                                  (rf_waddr_wb_o == exp_f8t_rd));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      f8_ord_q   <= F8ORD_S;
      f8_ord_bad <= 1'b0;
    end else if (f8_wb_hit) begin
      unique case (f8_ord_q)
        F8ORD_S: if (rf_waddr_wb_o == exp_f8s_rd) f8_ord_q <= F8ORD_M; else f8_ord_bad <= 1'b1;
        F8ORD_M: if (rf_waddr_wb_o == exp_f4m_rd) f8_ord_q <= F8ORD_T; else f8_ord_bad <= 1'b1;
        F8ORD_T: if (rf_waddr_wb_o == exp_f8t_rd) f8_ord_q <= F8ORD_DONE; else f8_ord_bad <= 1'b1;
        default: f8_ord_bad <= 1'b1;  // an extra write to one of these after all three - unexpected
      endcase
    end
  end

  //----------------------------------------------------------------------------
  // Test 4's ordering monitor - same construction as f8_ord_q above, but for
  // the THREE-engine case (U on the m2 engine, V on the fp4 engine, W on the
  // fp8 engine). x27/x19/x20 are written by nothing else in the program, so
  // watching every rf_we_wb_o to one of them yields exactly the delivery
  // sequence; any out-of-order retirement sets m2_ord_bad, checked at the end.
  // This is the check that MX_ORDER_DEPTH 15->20 and the third slot tag
  // actually work - two engines interleaving (Test 3) does not prove three do.
  //----------------------------------------------------------------------------
  typedef enum logic [1:0] { M2ORD_U, M2ORD_V, M2ORD_W, M2ORD_DONE } m2_ord_e;
  m2_ord_e m2_ord_q;
  logic    m2_ord_bad;

  wire m2_wb_hit = rf_we_wb_o && ((rf_waddr_wb_o == exp_m2u_rd) ||
                                  (rf_waddr_wb_o == exp_m2v_rd) ||
                                  (rf_waddr_wb_o == exp_m2w_rd));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      m2_ord_q   <= M2ORD_U;
      m2_ord_bad <= 1'b0;
    end else if (m2_wb_hit) begin
      unique case (m2_ord_q)
        M2ORD_U: if (rf_waddr_wb_o == exp_m2u_rd) m2_ord_q <= M2ORD_V; else m2_ord_bad <= 1'b1;
        M2ORD_V: if (rf_waddr_wb_o == exp_m2v_rd) m2_ord_q <= M2ORD_W; else m2_ord_bad <= 1'b1;
        M2ORD_W: if (rf_waddr_wb_o == exp_m2w_rd) m2_ord_q <= M2ORD_DONE; else m2_ord_bad <= 1'b1;
        default: m2_ord_bad <= 1'b1;  // an extra write to one of these after all three - unexpected
      endcase
    end
  end

  //----------------------------------------------------------------------------
  // Test 5 (residue mailbox robustness) writeback capture - ARMED, not
  // first-write-wins. Test 5's destinations x9 (interleaved fused) and x21
  // (MXFINAL res2) were each already written once earlier (P and Test 2's
  // MXFINAL), so the first-write-wins latches above already hold those earlier
  // values. These two latches are instead gated (armed) by wb_seen11_q - Test
  // 4's last writeback (W): since Test 5's instructions are strictly later in
  // the program than Test 4's, their writebacks retire after W's, so "the
  // first x9/x21 write seen once wb_seen11_q is set" is unambiguously Test 5's
  // own. Same decoupled-per-instruction rationale as every wb_seenN_q above.
  //----------------------------------------------------------------------------
  logic        wb_seen12_q;  logic [31:0] wb_data12_q;   // interleaved fused (x9)
  logic        wb_seen13_q;  logic [31:0] wb_data13_q;   // MXFINAL res2 (x21)

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen12_q <= 1'b0; wb_data12_q <= '0;
    end else if (!wb_seen12_q && wb_seen11_q && rf_we_wb_o && (rf_waddr_wb_o == exp_t5_fused_rd)) begin
      wb_seen12_q <= 1'b1; wb_data12_q <= rf_wdata_wb_o;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_seen13_q <= 1'b0; wb_data13_q <= '0;
    end else if (!wb_seen13_q && wb_seen11_q && rf_we_wb_o && (rf_waddr_wb_o == exp_t5_rfinal_rd)) begin
      wb_seen13_q <= 1'b1; wb_data13_q <= rf_wdata_wb_o;
    end
  end

  //----------------------------------------------------------------------------
  // Test 5 program-order monitor - the mixed order-queue check, on the RESULT
  // channel (not WB, because the MXDOTP retires with no writeback). The three
  // Test 5 offloads must retire in program order:
  //   MXDOTP(res2)   - we=0 (no architectural result)
  //   MXFUSED(fp4)   - we=1, rd=x9
  //   MXFINAL(res2)  - we=1, rd=x21
  // Gated by wb_seen11_q so it only watches Test 5's window (everything from
  // Tests 1-4 has already retired by the time W's writeback - wb_seen11_q -
  // has fired; the next result-channel handshake is MXDOTP(res2)'s). This is
  // the one ordering case Tests 3/4 do not cover: a DOTP (no-writeback) and a
  // FINAL slot interleaved with a FUSED slot, all ordered by the one order
  // queue. Any out-of-order retirement sets t5_ord_bad, checked at the end.
  //----------------------------------------------------------------------------
  typedef enum logic [1:0] { T5ORD_DOTP, T5ORD_FUSED, T5ORD_FINAL, T5ORD_DONE } t5_ord_e;
  t5_ord_e t5_ord_q;
  logic    t5_ord_bad;

  wire t5_res_hit = wb_seen11_q && xif_result_valid && xif_result_ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      t5_ord_q   <= T5ORD_DOTP;
      t5_ord_bad <= 1'b0;
    end else if (t5_res_hit) begin
      unique case (t5_ord_q)
        T5ORD_DOTP:  if (!xif_result_we)                                       t5_ord_q <= T5ORD_FUSED; else t5_ord_bad <= 1'b1;
        T5ORD_FUSED: if (xif_result_we && (xif_result_rd == exp_t5_fused_rd))  t5_ord_q <= T5ORD_FINAL; else t5_ord_bad <= 1'b1;
        T5ORD_FINAL: if (xif_result_we && (xif_result_rd == exp_t5_rfinal_rd)) t5_ord_q <= T5ORD_DONE;  else t5_ord_bad <= 1'b1;
        // Test 5's window closes once its FINAL has retired: every later
        // result belongs to Test 6 and is checked by the Test 6 monitor below
        // (which keeps the "no unexpected extra result" check at the end).
        T5ORD_DONE: ;
        default: t5_ord_bad <= 1'b1;
      endcase
    end
  end

  //----------------------------------------------------------------------------
  // Test 6 monitor - back-to-back MXDOTP/MXFINAL pairs, on the RESULT channel.
  // Starts where Test 5's window ends (t5_ord_q == T5ORD_DONE, registered, so
  // Test 5's own FINAL result is never counted here). Expected sequence, in
  // program order: DOTP (we=0), FINAL (we=1, rd=x21, data=84.0), repeated
  // T6_NUM_PAIRS times. Anything else - wrong kind, wrong rd/data, or a result
  // beyond the last pair - sets t6_bad. If a DOTP result is lost (the hang this
  // test was written for), t6_count_q stops short and the scoreboard times out
  // in SB_WAIT_T6_PAIRS.
  //----------------------------------------------------------------------------
  wire [7:0]  t6_num_results     = 8'(2 * u_instr_rom.T6_NUM_PAIRS);
  wire [4:0]  exp_t6_final_rd    = u_instr_rom.REG_T5_RFINAL_RESULT;      // x21
  wire [31:0] exp_t6_final_data  = u_instr_rom.MXFP4_RESIDUAL2_EXPECTED;  // 84.0

  logic [7:0] t6_count_q;
  logic       t6_bad;

  wire t6_res_hit = (t5_ord_q == T5ORD_DONE) && xif_result_valid && xif_result_ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      t6_count_q <= '0;
      t6_bad     <= 1'b0;
    end else if (t6_res_hit) begin
      if (t6_count_q >= t6_num_results)
        t6_bad <= 1'b1;                                     // result after the last pair
      else if (!t6_count_q[0]) begin
        if (xif_result_we) t6_bad <= 1'b1;                  // expected a DOTP (no writeback)
      end else begin
        if (!(xif_result_we && (xif_result_rd == exp_t6_final_rd) && (xif_result_data == exp_t6_final_data)))
          t6_bad <= 1'b1;                                   // expected FINAL x21 <= 84.0
      end
      t6_count_q <= t6_count_q + 8'd1;
    end
  end

  task automatic sb_fail(string msg);
`ifdef MX_PROGRAM_IMAGE
    // Program-image build: the Tests 1-6 scoreboard has no program to check
    // (a compiled program could even reuse one of their instruction words),
    // so its verdicts are ignored here; pass/fail is the program's EXIT code.
    return;
`endif
    $display("[%0t] FAIL: %s", $time, msg);
    fail_count++;
    sb_fail_this_cycle = 1'b1;
    sb_fail_msg        = msg;
  endtask

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      sb_state <= SB_WAIT_P_ISSUE;
    end else begin
      // If a failure was flagged this cycle, transition to SB_FAIL and hold.
      if (sb_fail_this_cycle) begin
        sb_state <= SB_FAIL;
      end else begin
        unique case (sb_state)

        //----------------------------------------------------------------
        // MXFUSED x3 back-to-back (P, Q, R) - the overlap milestone's own
        // test (see instr_rom.sv header). Structured by PHASE, not by
        // instruction: all three ISSUEs are checked first, then all three
        // COMMITs, then all three RESULTs, then all three WBs - unlike
        // every other test in this file, which fully completes one
        // instruction's issue->commit->result->wb before starting the
        // next. That's deliberate: this phase-interleaved structure is
        // what actually requires Q to be issued while P is still mid-
        // flight, rather than merely running three single-instruction
        // tests back-to-back in the program (which would prove nothing
        // new about overlap - see instr_rom.sv's header for why the old
        // single-instruction test doesn't exercise this at all).
        //
        // Every state below POLLS an already-captured latch (declared
        // earlier, alongside the RF writeback capture) rather than watching
        // a live XIF signal directly - the first real overlap run showed
        // why that distinction matters: with true overlap, P's/Q's own
        // commit can arrive while the scoreboard is still working through
        // an EARLIER phase, and a transient pulse not watched for at the
        // moment it fires is simply gone. See that capture section's own
        // header for the full story.
        //----------------------------------------------------------------

        SB_WAIT_P_ISSUE: begin
          if (p_issue_seen_q) begin
            if (!p_issue_accept_q) begin
              sb_fail("MXFUSED(P) instruction was not accepted at issue");
            end else if (!p_issue_wb_q) begin
              sb_fail("MXFUSED(P) issue_resp.writeback was not asserted");
            end else if (!p_issue_dr_q) begin
              sb_fail("MXFUSED(P) issue_resp.dualread was not asserted");
            end else if ((p_issue_a_q !== exp_fa_val) || (p_issue_b_q !== exp_fb_val) || (p_issue_rs3_q !== exp_frs3_val)) begin
              sb_fail($sformatf("MXFUSED(P) operand mismatch at issue: A=0x%0h B=0x%0h RS3=0x%0h (expected 0x%0h,0x%0h,0x%0h)",
                                 p_issue_a_q, p_issue_b_q, p_issue_rs3_q, exp_fa_val, exp_fb_val, exp_frs3_val));
            end else begin
              $display("[%0t] FUSED(P) ISSUE  ok: id=%0d A=0x%0h B=0x%0h RS3=0x%0h",
                        p_issue_time_q, p_issue_id_q, p_issue_a_q, p_issue_b_q, p_issue_rs3_q);
              sb_state <= SB_WAIT_Q_ISSUE;
            end
          end
        end

        SB_WAIT_Q_ISSUE: begin
          if (q_issue_seen_q) begin
            if (!q_issue_accept_q) begin
              sb_fail("MXFUSED(Q) instruction was not accepted at issue - check MX_FUSED_PENDING_DEPTH/issue_ready if this fires");
            end else if (!q_issue_wb_q) begin
              sb_fail("MXFUSED(Q) issue_resp.writeback was not asserted");
            end else if (!q_issue_dr_q) begin
              sb_fail("MXFUSED(Q) issue_resp.dualread was not asserted");
            end else if ((q_issue_a_q !== exp_qa_val) || (q_issue_b_q !== exp_qb_val) || (q_issue_rs3_q !== exp_frs3_q_val)) begin
              sb_fail($sformatf("MXFUSED(Q) operand mismatch at issue: A=0x%0h B=0x%0h RS3=0x%0h (expected 0x%0h,0x%0h,0x%0h)",
                                 q_issue_a_q, q_issue_b_q, q_issue_rs3_q, exp_qa_val, exp_qb_val, exp_frs3_q_val));
            end else begin
              $display("[%0t] FUSED(Q) ISSUE  ok: id=%0d A=0x%0h B=0x%0h RS3=0x%0h",
                        q_issue_time_q, q_issue_id_q, q_issue_a_q, q_issue_b_q, q_issue_rs3_q);
              sb_state <= SB_WAIT_R_ISSUE;
            end
          end
        end

        SB_WAIT_R_ISSUE: begin
          if (r_issue_seen_q) begin
            if (!r_issue_accept_q) begin
              sb_fail("MXFUSED(R) instruction was not accepted at issue - check MX_FUSED_PENDING_DEPTH/issue_ready if this fires");
            end else if (!r_issue_wb_q) begin
              sb_fail("MXFUSED(R) issue_resp.writeback was not asserted");
            end else if (!r_issue_dr_q) begin
              sb_fail("MXFUSED(R) issue_resp.dualread was not asserted");
            end else if ((r_issue_a_q !== exp_ra_val_ovl) || (r_issue_b_q !== exp_rb_val_ovl) || (r_issue_rs3_q !== exp_rrs3_val)) begin
              sb_fail($sformatf("MXFUSED(R) operand mismatch at issue: A=0x%0h B=0x%0h RS3=0x%0h (expected 0x%0h,0x%0h,0x%0h)",
                                 r_issue_a_q, r_issue_b_q, r_issue_rs3_q, exp_ra_val_ovl, exp_rb_val_ovl, exp_rrs3_val));
            end else begin
              $display("[%0t] FUSED(R) ISSUE  ok: id=%0d A=0x%0h B=0x%0h RS3=0x%0h",
                        r_issue_time_q, r_issue_id_q, r_issue_a_q, r_issue_b_q, r_issue_rs3_q);
              sb_state <= SB_WAIT_P_COMMIT;
            end
          end
        end

        // Commit capture (declared earlier, alongside issue/result capture)
        // is POSITIONAL (1st/2nd/3rd commit_valid pulse seen anywhere),
        // cross-checked here against each instruction's own issue-captured
        // id - that comparison is what keeps "commits must arrive in P,Q,R
        // program order" a real, checked property rather than an assumption.

        SB_WAIT_P_COMMIT: begin
          if (commit_capture_idx_q > 2'd0) begin
            if (commit_capture_id_q[0] !== p_issue_id_q) begin
              sb_fail($sformatf("MXFUSED(P) commit id mismatch: got %0d expected %0d - commits must arrive in P,Q,R program order", commit_capture_id_q[0], p_issue_id_q));
            end else if (commit_capture_kill_q[0]) begin
              sb_fail("MXFUSED(P) instruction was killed at commit (unexpected for this program)");
            end else begin
              $display("[%0t] FUSED(P) COMMIT ok: id=%0d, commit_kill=0", $time, commit_capture_id_q[0]);
              sb_state <= SB_WAIT_Q_COMMIT;
            end
          end
        end

        SB_WAIT_Q_COMMIT: begin
          if (commit_capture_idx_q > 2'd1) begin
            if (commit_capture_id_q[1] !== q_issue_id_q) begin
              sb_fail($sformatf("MXFUSED(Q) commit id mismatch: got %0d expected %0d - commits must arrive in P,Q,R program order", commit_capture_id_q[1], q_issue_id_q));
            end else if (commit_capture_kill_q[1]) begin
              sb_fail("MXFUSED(Q) instruction was killed at commit (unexpected for this program)");
            end else begin
              $display("[%0t] FUSED(Q) COMMIT ok: id=%0d, commit_kill=0", $time, commit_capture_id_q[1]);
              sb_state <= SB_WAIT_R_COMMIT;
            end
          end
        end

        SB_WAIT_R_COMMIT: begin
          if (commit_capture_idx_q > 2'd2) begin
            if (commit_capture_id_q[2] !== r_issue_id_q) begin
              sb_fail($sformatf("MXFUSED(R) commit id mismatch: got %0d expected %0d - commits must arrive in P,Q,R program order", commit_capture_id_q[2], r_issue_id_q));
            end else if (commit_capture_kill_q[2]) begin
              sb_fail("MXFUSED(R) instruction was killed at commit (unexpected for this program)");
            end else begin
              $display("[%0t] FUSED(R) COMMIT ok: id=%0d, commit_kill=0", $time, commit_capture_id_q[2]);
              sb_state <= SB_WAIT_P_RESULT;
            end
          end
        end

        // Results (and WBs below) MUST arrive in P, Q, R order - the shared
        // order queue enforces program order regardless of which of the
        // three actually finished computing first inside the engine (see
        // mxdotp_xif.sv's milestone header) - so checking them in this
        // fixed sequence is itself a real check, not just a convenient
        // structure: if the engine or the order queue ever delivered them
        // out of order, the id check below would catch it immediately
        // (xif_result_id would be Q's or R's id when P's is still expected).

        SB_WAIT_P_RESULT: begin
          if (result_capture_idx_q > 2'd0) begin
            if (result_capture_id_q[0] !== p_issue_id_q) begin
              sb_fail($sformatf("MXFUSED(P) result id mismatch: got %0d expected %0d - results must arrive in P,Q,R program order", result_capture_id_q[0], p_issue_id_q));
            end else if (result_capture_rd_q[0] !== exp_fused_rd) begin
              sb_fail($sformatf("MXFUSED(P) result rd mismatch: got %0d expected %0d", result_capture_rd_q[0], exp_fused_rd));
            end else if (!result_capture_we_q[0]) begin
              sb_fail("MXFUSED(P) result.we was not asserted");
            end else if (result_capture_data_q[0] !== exp_fused_data) begin
              sb_fail($sformatf("MXFUSED(P) result.data unexpected: got 0x%0h, expected 0x%0h", result_capture_data_q[0], exp_fused_data));
            end else begin
              $display("[%0t] FUSED(P) RESULT ok: id=%0d rd=%0d data=0x%0h we=%0d",
                        result_capture_time_q[0], result_capture_id_q[0], result_capture_rd_q[0], result_capture_data_q[0], result_capture_we_q[0]);
              sb_state <= SB_WAIT_Q_RESULT;
            end
          end
        end

        SB_WAIT_Q_RESULT: begin
          if (result_capture_idx_q > 2'd1) begin
            if (result_capture_id_q[1] !== q_issue_id_q) begin
              sb_fail($sformatf("MXFUSED(Q) result id mismatch: got %0d expected %0d - results must arrive in P,Q,R program order", result_capture_id_q[1], q_issue_id_q));
            end else if (result_capture_rd_q[1] !== exp_fused_q_rd) begin
              sb_fail($sformatf("MXFUSED(Q) result rd mismatch: got %0d expected %0d", result_capture_rd_q[1], exp_fused_q_rd));
            end else if (!result_capture_we_q[1]) begin
              sb_fail("MXFUSED(Q) result.we was not asserted");
            end else if (result_capture_data_q[1] !== exp_fused_q_data) begin
              sb_fail($sformatf("MXFUSED(Q) result.data unexpected: got 0x%0h, expected 0x%0h", result_capture_data_q[1], exp_fused_q_data));
            end else begin
              $display("[%0t] FUSED(Q) RESULT ok: id=%0d rd=%0d data=0x%0h we=%0d",
                        result_capture_time_q[1], result_capture_id_q[1], result_capture_rd_q[1], result_capture_data_q[1], result_capture_we_q[1]);
              sb_state <= SB_WAIT_R_RESULT;
            end
          end
        end

        SB_WAIT_R_RESULT: begin
          if (result_capture_idx_q > 2'd2) begin
            if (result_capture_id_q[2] !== r_issue_id_q) begin
              sb_fail($sformatf("MXFUSED(R) result id mismatch: got %0d expected %0d - results must arrive in P,Q,R program order", result_capture_id_q[2], r_issue_id_q));
            end else if (result_capture_rd_q[2] !== exp_fused_r_rd) begin
              sb_fail($sformatf("MXFUSED(R) result rd mismatch: got %0d expected %0d", result_capture_rd_q[2], exp_fused_r_rd));
            end else if (!result_capture_we_q[2]) begin
              sb_fail("MXFUSED(R) result.we was not asserted");
            end else if (result_capture_data_q[2] !== exp_fused_r_data) begin
              sb_fail($sformatf("MXFUSED(R) result.data unexpected: got 0x%0h, expected 0x%0h", result_capture_data_q[2], exp_fused_r_data));
            end else begin
              $display("[%0t] FUSED(R) RESULT ok: id=%0d rd=%0d data=0x%0h we=%0d",
                        result_capture_time_q[2], result_capture_id_q[2], result_capture_rd_q[2], result_capture_data_q[2], result_capture_we_q[2]);
              sb_state <= SB_WAIT_P_WB;
            end
          end
        end

        SB_WAIT_P_WB: begin
          if (wb_seen_q) begin
            if (wb_data_q !== exp_fused_data) begin
              sb_fail($sformatf("Register file write mismatch: x%0d = 0x%0h, expected 0x%0h", exp_fused_rd, wb_data_q, exp_fused_data));
            end else begin
              $display("[%0t] FUSED(P) WB     ok: x%0d <= 0x%0h", $time, exp_fused_rd, wb_data_q);
              sb_state <= SB_WAIT_Q_WB;
            end
          end
        end

        SB_WAIT_Q_WB: begin
          if (wb_seen4_q) begin
            if (wb_data4_q !== exp_fused_q_data) begin
              sb_fail($sformatf("Register file write mismatch: x%0d = 0x%0h, expected 0x%0h", exp_fused_q_rd, wb_data4_q, exp_fused_q_data));
            end else begin
              $display("[%0t] FUSED(Q) WB     ok: x%0d <= 0x%0h", $time, exp_fused_q_rd, wb_data4_q);
              sb_state <= SB_WAIT_R_WB;
            end
          end
        end

        SB_WAIT_R_WB: begin
          if (wb_seen5_q) begin
            if (wb_data5_q !== exp_fused_r_data) begin
              sb_fail($sformatf("Register file write mismatch: x%0d = 0x%0h, expected 0x%0h", exp_fused_r_rd, wb_data5_q, exp_fused_r_data));
            end else begin
              $display("[%0t] FUSED(R) WB     ok: x%0d <= 0x%0h", $time, exp_fused_r_rd, wb_data5_q);
              // Overlap diagnostic - informational only, does not gate pass/fail. If Q was
              // issued before P's result arrived (and likewise R before Q's), that's direct
              // evidence multiple MXFUSED instructions really were simultaneously occupying
              // different stages of mxdotp_fused_engine.sv's pipeline this run - the actual
              // thing this test exists to exercise, not just "three correct results
              // eventually showed up".
              if ((q_issue_time_q < result_capture_time_q[0]) && (r_issue_time_q < result_capture_time_q[1])) begin
                $display("[%0t] OVERLAP CONFIRMED: Q issued @%0t (before P resulted @%0t), R issued @%0t (before Q resulted @%0t)",
                          $time, q_issue_time_q, result_capture_time_q[0], r_issue_time_q, result_capture_time_q[1]);
              end else begin
                $display("[%0t] NOTE: no overlap observed this run (Q issued @%0t, P resulted @%0t, R issued @%0t, Q resulted @%0t) - not a failure, but worth a second look if unexpected",
                          $time, q_issue_time_q, result_capture_time_q[0], r_issue_time_q, result_capture_time_q[1]);
              end
              sb_state <= SB_WAIT_DUALREAD_ISSUE;
            end
          end
        end

        //----------------------------------------------------------------
        // MX_FUNCT3_DUALREAD_TEST: validation-only, not part of the real
        // MXDOTP ISA. rs1=x10 requests a paired {x11,x10} dual-read;
        // rd should end up holding x11's value (the upper/"+1" half),
        // proving cv32e40x_core.sv's dual-read mechanism end-to-end.
        //----------------------------------------------------------------

        SB_WAIT_DUALREAD_ISSUE: begin
          if (dr_issue_seen_q) begin
            if (!dr_issue_accept_q) begin
              sb_fail("MXDUALREAD_TEST instruction was not accepted at issue");
            end else if (!dr_issue_wb_q) begin
              sb_fail("MXDUALREAD_TEST issue_resp.writeback was not asserted");
            end else if (!dr_issue_dr_q) begin
              sb_fail("MXDUALREAD_TEST issue_resp.dualread was not asserted");
            end else if (dr_issue_rs1w_q !== {exp_dualread_hi, exp_dualread_lo}) begin
              sb_fail($sformatf("MXDUALREAD_TEST paired rs1 mismatch at issue: got 0x%0h (expected {hi=0x%0h,lo=0x%0h})",
                                 dr_issue_rs1w_q, exp_dualread_hi, exp_dualread_lo));
            end else begin
              $display("[%0t] DUALREAD ISSUE ok: id=%0d rs1={hi=0x%0h,lo=0x%0h}",
                        dr_issue_time_q, dr_issue_id_q, dr_issue_rs1w_q[63:32], dr_issue_rs1w_q[31:0]);
              sb_state <= SB_WAIT_DUALREAD_COMMIT;
            end
          end
        end

        SB_WAIT_DUALREAD_COMMIT: begin
          if (commit_capture_idx_q > 3'd3) begin
            if (commit_capture_id_q[3] !== dr_issue_id_q) begin
              sb_fail($sformatf("MXDUALREAD_TEST commit id mismatch: got %0d expected %0d", commit_capture_id_q[3], dr_issue_id_q));
            end else if (commit_capture_kill_q[3]) begin
              sb_fail("MXDUALREAD_TEST instruction was killed at commit (unexpected for this program)");
            end else begin
              $display("[%0t] DUALREAD COMMIT ok: id=%0d, commit_kill=0", $time, commit_capture_id_q[3]);
              sb_state <= SB_WAIT_DUALREAD_RESULT;
            end
          end
        end

        SB_WAIT_DUALREAD_RESULT: begin
          if (result_capture_idx_q > 3'd3) begin
            if (result_capture_id_q[3] !== dr_issue_id_q) begin
              sb_fail($sformatf("MXDUALREAD_TEST result id mismatch: got %0d expected %0d", result_capture_id_q[3], dr_issue_id_q));
            end else if (result_capture_rd_q[3] !== exp_dualread_rd) begin
              sb_fail($sformatf("MXDUALREAD_TEST result rd mismatch: got %0d expected %0d", result_capture_rd_q[3], exp_dualread_rd));
            end else if (!result_capture_we_q[3]) begin
              sb_fail("MXDUALREAD_TEST result.we was not asserted");
            end else if (result_capture_data_q[3] !== exp_dualread_data) begin
              sb_fail($sformatf("MXDUALREAD_TEST result.data unexpected: got 0x%0h, expected 0x%0h (x11's value) - dual-read mechanism did not assemble the paired read correctly",
                                 result_capture_data_q[3], exp_dualread_data));
            end else begin
              $display("[%0t] DUALREAD RESULT ok: id=%0d rd=%0d data=0x%0h we=%0d",
                        result_capture_time_q[3], result_capture_id_q[3], result_capture_rd_q[3], result_capture_data_q[3], result_capture_we_q[3]);
              sb_state <= SB_WAIT_DUALREAD_WB;
            end
          end
        end

        SB_WAIT_DUALREAD_WB: begin
          if (wb_seen2_q) begin
            if (wb_data2_q !== exp_dualread_data) begin
              sb_fail($sformatf("Register file write mismatch: x%0d = 0x%0h, expected 0x%0h", exp_dualread_rd, wb_data2_q, exp_dualread_data));
            end else begin
              $display("[%0t] DUALREAD WB     ok: x%0d <= 0x%0h", $time, exp_dualread_rd, wb_data2_q);
              sb_state <= SB_WAIT_RDOTP_ISSUE;
            end
          end
        end

        //----------------------------------------------------------------
        // MX_FMT_MXFP4_RESIDUAL: k=16, with residue. Same funct3 codes as
        // the k=8 datapath (MX_FUNCT3_DOTP/MX_FUNCT3_FINAL), dispatched by
        // mx_format instead - see instr_rom.sv header for the full
        // algorithm and hand/Python-derived expected value.
        //----------------------------------------------------------------

        SB_WAIT_RDOTP_ISSUE: begin
          if (rdotp_issue_seen_q) begin
            if (!rdotp_issue_accept_q) begin
              sb_fail("MXDOTP(residual) instruction was not accepted at issue");
            end else if (rdotp_issue_wb_q) begin
              sb_fail("MXDOTP(residual) issue_resp.writeback was asserted (expected 0)");
            end else if (!rdotp_issue_dr_q) begin
              sb_fail("MXDOTP(residual) issue_resp.dualread was not asserted");
            end else if (rdotp_issue_a_q !== exp_ra_val) begin
              sb_fail($sformatf("MXDOTP(residual) A mismatch at issue: got 0x%0h expected 0x%0h",
                                 rdotp_issue_a_q, exp_ra_val));
            end else if (rdotp_issue_b_q !== exp_rb_val) begin
              sb_fail($sformatf("MXDOTP(residual) B mismatch at issue: got 0x%0h expected 0x%0h",
                                 rdotp_issue_b_q, exp_rb_val));
            end else if (rdotp_issue_ar_q !== exp_rar_val) begin
              sb_fail($sformatf("MXDOTP(residual) AR mismatch at issue: got 0x%0h expected 0x%0h",
                                 rdotp_issue_ar_q, exp_rar_val));
            end else begin
              $display("[%0t] RDOTP ISSUE  ok: id=%0d A=0x%0h B=0x%0h AR=0x%0h",
                        rdotp_issue_time_q, rdotp_issue_id_q, rdotp_issue_a_q, rdotp_issue_b_q, rdotp_issue_ar_q);
              sb_state <= SB_WAIT_RDOTP_COMMIT;
            end
          end
        end

        SB_WAIT_RDOTP_COMMIT: begin
          if (commit_capture_idx_q > 3'd4) begin
            if (commit_capture_id_q[4] !== rdotp_issue_id_q) begin
              sb_fail($sformatf("MXDOTP(residual) commit id mismatch: got %0d expected %0d", commit_capture_id_q[4], rdotp_issue_id_q));
            end else if (commit_capture_kill_q[4]) begin
              sb_fail("MXDOTP(residual) instruction was killed at commit (unexpected for this program)");
            end else begin
              $display("[%0t] RDOTP COMMIT ok: id=%0d, commit_kill=0", $time, commit_capture_id_q[4]);
              sb_state <= SB_WAIT_RDOTP_RESULT;
            end
          end
        end

        SB_WAIT_RDOTP_RESULT: begin
          if (result_capture_idx_q > 3'd4) begin
            if (result_capture_id_q[4] !== rdotp_issue_id_q) begin
              sb_fail($sformatf("MXDOTP(residual) result id mismatch: got %0d expected %0d", result_capture_id_q[4], rdotp_issue_id_q));
            end else if (result_capture_we_q[4]) begin
              sb_fail("MXDOTP(residual) result.we was asserted (expected 0 - no architectural result)");
            end else begin
              $display("[%0t] RDOTP RESULT ok: id=%0d we=%0d (no writeback, as expected)",
                        result_capture_time_q[4], result_capture_id_q[4], result_capture_we_q[4]);
              sb_state <= SB_WAIT_RFINAL_ISSUE;
            end
          end
        end

        SB_WAIT_RFINAL_ISSUE: begin
          if (rfinal_issue_seen_q) begin
            if (!rfinal_issue_accept_q) begin
              sb_fail("MXFINAL(residual) instruction was not accepted at issue");
            end else if (!rfinal_issue_wb_q) begin
              sb_fail("MXFINAL(residual) issue_resp.writeback was not asserted");
            end else if (rfinal_issue_dr_q) begin
              sb_fail("MXFINAL(residual) issue_resp.dualread was asserted (expected 0 - scales/old_acc are plain 32-bit reads)");
            end else if ((rfinal_issue_scales_q !== exp_rscales) || (rfinal_issue_oldacc_q !== exp_rold_acc)) begin
              sb_fail($sformatf("MXFINAL(residual) operand mismatch at issue: scales=0x%0h old_acc=0x%0h (expected 0x%0h,0x%0h)",
                                 rfinal_issue_scales_q, rfinal_issue_oldacc_q, exp_rscales, exp_rold_acc));
            end else begin
              $display("[%0t] RFINAL ISSUE ok: id=%0d scales=0x%0h old_acc=0x%0h",
                        rfinal_issue_time_q, rfinal_issue_id_q, rfinal_issue_scales_q, rfinal_issue_oldacc_q);
              sb_state <= SB_WAIT_RFINAL_COMMIT;
            end
          end
        end

        SB_WAIT_RFINAL_COMMIT: begin
          if (commit_capture_idx_q > 3'd5) begin
            if (commit_capture_id_q[5] !== rfinal_issue_id_q) begin
              sb_fail($sformatf("MXFINAL(residual) commit id mismatch: got %0d expected %0d", commit_capture_id_q[5], rfinal_issue_id_q));
            end else if (commit_capture_kill_q[5]) begin
              sb_fail("MXFINAL(residual) instruction was killed at commit (unexpected for this program)");
            end else begin
              $display("[%0t] RFINAL COMMIT ok: id=%0d, commit_kill=0", $time, commit_capture_id_q[5]);
              sb_state <= SB_WAIT_RFINAL_RESULT;
            end
          end
        end

        SB_WAIT_RFINAL_RESULT: begin
          if (result_capture_idx_q > 3'd5) begin
            if (result_capture_id_q[5] !== rfinal_issue_id_q) begin
              sb_fail($sformatf("MXFINAL(residual) result id mismatch: got %0d expected %0d", result_capture_id_q[5], rfinal_issue_id_q));
            end else if (result_capture_rd_q[5] !== exp_rfinal_rd) begin
              sb_fail($sformatf("MXFINAL(residual) result rd mismatch: got %0d expected %0d", result_capture_rd_q[5], exp_rfinal_rd));
            end else if (!result_capture_we_q[5]) begin
              sb_fail("MXFINAL(residual) result.we was not asserted");
            end else if (result_capture_data_q[5] !== exp_rfinal_data) begin
              sb_fail($sformatf("MXFINAL(residual) result.data unexpected: got 0x%0h, expected 0x%0h",
                                 result_capture_data_q[5], exp_rfinal_data));
            end else begin
              $display("[%0t] RFINAL RESULT ok: id=%0d rd=%0d data=0x%0h we=%0d",
                        result_capture_time_q[5], result_capture_id_q[5], result_capture_rd_q[5], result_capture_data_q[5], result_capture_we_q[5]);
              sb_state <= SB_WAIT_RFINAL_WB;
            end
          end
        end

        SB_WAIT_RFINAL_WB: begin
          if (wb_seen3_q) begin
            if (wb_data3_q !== exp_rfinal_data) begin
              sb_fail($sformatf("Register file write mismatch: x%0d = 0x%0h, expected 0x%0h", exp_rfinal_rd, wb_data3_q, exp_rfinal_data));
            end else begin
              $display("[%0t] RFINAL WB    ok: x%0d <= 0x%0h", $time, exp_rfinal_rd, wb_data3_q);
              sb_state <= SB_WAIT_F8S_WB;
            end
          end
        end

        SB_WAIT_F8S_WB: begin
          if (wb_seen6_q) begin
            if (wb_data6_q !== exp_f8s_data) begin
              sb_fail($sformatf("MXFP8(S,E4M3) result mismatch: x%0d = 0x%0h, expected 0x%0h", exp_f8s_rd, wb_data6_q, exp_f8s_data));
            end else begin
              $display("[%0t] FUSED8(S,E4M3) WB ok: x%0d <= 0x%0h", $time, exp_f8s_rd, wb_data6_q);
              sb_state <= SB_WAIT_F8M_WB;
            end
          end
        end

        SB_WAIT_F8M_WB: begin
          if (wb_seen7_q) begin
            if (wb_data7_q !== exp_f4m_data) begin
              sb_fail($sformatf("MXFP4(M) result mismatch: x%0d = 0x%0h, expected 0x%0h", exp_f4m_rd, wb_data7_q, exp_f4m_data));
            end else begin
              $display("[%0t] FUSED(M,MXFP4) WB ok: x%0d <= 0x%0h", $time, exp_f4m_rd, wb_data7_q);
              sb_state <= SB_WAIT_F8T_WB;
            end
          end
        end

        SB_WAIT_F8T_WB: begin
          if (wb_seen8_q) begin
            if (wb_data8_q !== exp_f8t_data) begin
              sb_fail($sformatf("MXFP8(T,E5M2) result mismatch: x%0d = 0x%0h, expected 0x%0h", exp_f8t_rd, wb_data8_q, exp_f8t_data));
            end else if (f8_ord_bad) begin
              sb_fail("Cross-engine ordering violation: S/M/T writebacks did not retire in program order (S,M,T) - two-slot order queue delivered out of order");
            end else begin
              $display("[%0t] FUSED8(T,E5M2) WB ok: x%0d <= 0x%0h", $time, exp_f8t_rd, wb_data8_q);
              $display("[%0t] CROSS-ENGINE ORDER ok: S(x%0d,fp8) -> M(x%0d,fp4) -> T(x%0d,fp8) retired in program order",
                        $time, exp_f8s_rd, exp_f4m_rd, exp_f8t_rd);
              sb_state <= SB_WAIT_M2U_WB;
            end
          end
        end

        //----------------------------------------------------------------
        // Test 4: M2XFP4 (U) + three-engine overlap (U on m2, V on fp4,
        // W on fp8). U's expected value is deliberately NOT reachable by
        // any other engine on the same operands (plain MXFP4 would give
        // 21.0, not 29.875), so a mis-route or a fall-through to the fp4
        // engine's safe-inert SoP=0 stub fails here rather than passing
        // by coincidence. See instr_rom.sv's Test 4 header.
        //----------------------------------------------------------------

        SB_WAIT_M2U_WB: begin
          if (wb_seen9_q) begin
            if (wb_data9_q !== exp_m2u_data) begin
              sb_fail($sformatf("M2XFP4(U) result mismatch: x%0d = 0x%0h, expected 0x%0h (plain MXFP4 on the same operands would give 0x41A80000 = 21.0 - if that is what came back, U was routed to the fp4 engine or fell into its SoP=0 stub)",
                                 exp_m2u_rd, wb_data9_q, exp_m2u_data));
            end else begin
              $display("[%0t] FUSED_M2(U,M2XFP4) WB ok: x%0d <= 0x%0h (29.875)", $time, exp_m2u_rd, wb_data9_q);
              sb_state <= SB_WAIT_M2V_WB;
            end
          end
        end

        SB_WAIT_M2V_WB: begin
          if (wb_seen10_q) begin
            if (wb_data10_q !== exp_m2v_data) begin
              sb_fail($sformatf("MXFP4(V) result mismatch: x%0d = 0x%0h, expected 0x%0h (V shares U's rs3 word, which carries M2XFP4 metadata at [56:49] - the fp4 engine must ignore rs3[63:48] entirely)",
                                 exp_m2v_rd, wb_data10_q, exp_m2v_data));
            end else begin
              $display("[%0t] FUSED(V,MXFP4) WB ok: x%0d <= 0x%0h", $time, exp_m2v_rd, wb_data10_q);
              sb_state <= SB_WAIT_M2W_WB;
            end
          end
        end

        SB_WAIT_M2W_WB: begin
          if (wb_seen11_q) begin
            if (wb_data11_q !== exp_m2w_data) begin
              sb_fail($sformatf("MXFP8(W,E4M3) result mismatch: x%0d = 0x%0h, expected 0x%0h (W shares U's rs3 word - the fp8 engine must read only rs3[48]=0 -> E4M3 out of the metadata range)",
                                 exp_m2w_rd, wb_data11_q, exp_m2w_data));
            end else if (m2_ord_bad) begin
              sb_fail("Three-engine ordering violation: U/V/W writebacks did not retire in program order (U,V,W) - the three-slot order queue delivered out of order");
            end else begin
              $display("[%0t] FUSED8(W,E4M3) WB ok: x%0d <= 0x%0h", $time, exp_m2w_rd, wb_data11_q);
              $display("[%0t] THREE-ENGINE ORDER ok: U(x%0d,m2) -> V(x%0d,fp4) -> W(x%0d,fp8) retired in program order",
                        $time, exp_m2u_rd, exp_m2v_rd, exp_m2w_rd);
              sb_state <= SB_WAIT_T5_FUSED_WB;
            end
          end
        end

        //----------------------------------------------------------------
        // Test 5: MXDOTP/MXFINAL mailbox robustness + 2nd numeric residue.
        // An UNRELATED MXFUSED(fp4) sits between the DOTP and the FINAL. The
        // mailbox must carry p1'/p2' across it (proven by MXFINAL's value
        // being correct despite the intervening instruction), and the
        // DOTP/FUSED/FINAL trio must retire in program order (t5_ord). WBs
        // arrive as FUSED(x9) then FINAL(x21) - the DOTP has no writeback.
        // See instr_rom.sv's Test 5 header.
        //----------------------------------------------------------------
        SB_WAIT_T5_FUSED_WB: begin
          if (wb_seen12_q) begin
            if (wb_data12_q !== exp_t5_fused_data) begin
              sb_fail($sformatf("Test 5 interleaved MXFUSED(MXFP4) result mismatch: x%0d = 0x%0h, expected 0x%0h",
                                 exp_t5_fused_rd, wb_data12_q, exp_t5_fused_data));
            end else begin
              $display("[%0t] T5 FUSED(interleaved) WB ok: x%0d <= 0x%0h", $time, exp_t5_fused_rd, wb_data12_q);
              sb_state <= SB_WAIT_T5_RFINAL_WB;
            end
          end
        end

        SB_WAIT_T5_RFINAL_WB: begin
          if (wb_seen13_q) begin
            if (wb_data13_q !== exp_t5_rfinal_data) begin
              sb_fail($sformatf("Test 5 MXFINAL(res2) result mismatch: x%0d = 0x%0h, expected 0x%0h - the mailbox p1/p2 did not survive the interleaved MXFUSED, or the 2nd residue case is miscomputed",
                                 exp_t5_rfinal_rd, wb_data13_q, exp_t5_rfinal_data));
            end else if (t5_ord_bad) begin
              sb_fail("Test 5 ordering violation: MXDOTP/MXFUSED/MXFINAL did not retire in program order - the order queue mishandled a DOTP(no-writeback) and FINAL slot interleaved with a FUSED slot");
            end else begin
              $display("[%0t] T5 MXFINAL(res2) WB ok: x%0d <= 0x%0h (mailbox survived interleaved MXFUSED)", $time, exp_t5_rfinal_rd, wb_data13_q);
              $display("[%0t] T5 ORDER ok: MXDOTP(no-wb) -> MXFUSED(x%0d) -> MXFINAL(x%0d) retired in program order",
                        $time, exp_t5_fused_rd, exp_t5_rfinal_rd);
              sb_state <= SB_WAIT_T6_PAIRS;
            end
          end
        end

        //----------------------------------------------------------------
        // Test 6: back-to-back MXDOTP/MXFINAL pairs. Waits for the Test 6
        // monitor to see all 2*T6_NUM_PAIRS results; see that monitor and
        // instr_rom.sv's Test 6 header.
        //----------------------------------------------------------------
        SB_WAIT_T6_PAIRS: begin
          if (t6_bad) begin
            sb_fail("Test 6 back-to-back MXDOTP/MXFINAL pairs: wrong result sequence (expected DOTP we=0, then FINAL x21 <= 84.0, per pair, in program order, and nothing after the last pair)");
          end else if (t6_count_q == t6_num_results) begin
            $display("[%0t] T6 PAIRS ok: %0d back-to-back MXDOTP/MXFINAL pairs retired in program order, every MXFINAL x%0d <= 0x%0h",
                      $time, t6_num_results / 2, exp_t6_final_rd, exp_t6_final_data);
            $display("=====================================================");
            $display(" PASS: MXFUSED(P,Q,R overlap) -> MXDUALREAD_TEST -> MXDOTP/MXFINAL(residual) -> MXFP8(E4M3,E5M2)+overlap -> M2XFP4+3-engine overlap -> MXDOTP/MXFINAL mailbox robustness -> back-to-back MXDOTP/MXFINAL pairs all traversed");
            $display("=====================================================");
            pass_count++;
            sb_state <= SB_DONE;
          end
        end

        SB_DONE:  ; // latched, nothing further to do
        SB_FAIL:  ; // latched, nothing further to do

        default: sb_fail("Scoreboard reached an unknown state");

        endcase
      end
    end
  end

  //----------------------------------------------------------------------------
  // Watchdog: bounds simulation time and reports final PASS/FAIL
  //
  // In the stream-measurement build (make stream, MX_STREAM_TEST) instr_rom.sv
  // holds the directed stream program instead of Tests 1-5, so the scoreboard
  // never leaves its first state and is not consulted: the run stops after a
  // fixed window and the [XIFMON] log is the output.
  //----------------------------------------------------------------------------

`ifdef MX_PROGRAM_IMAGE
  // Pipeline taps for waveform inspection (program-image build only): the PC
  // and valid bit of the instruction held in each stage register, as named
  // signals in the VCD (the pipe structs are traced as flat vectors).
  wire [31:0] dbg_pc_if = dut.core_i.pc_if;
  wire [31:0] dbg_pc_id = dut.core_i.if_id_pipe.pc;
  wire        dbg_v_id  = dut.core_i.if_id_pipe.instr_valid;
  wire [31:0] dbg_pc_ex = dut.core_i.id_ex_pipe.pc;
  wire        dbg_v_ex  = dut.core_i.id_ex_pipe.instr_valid;
  wire [31:0] dbg_pc_wb = dut.core_i.ex_wb_pipe.pc;
  wire        dbg_v_wb  = dut.core_i.ex_wb_pipe.instr_valid;

  // Program-image build (make loop): the program ends itself by writing its
  // exit code to mem_model's EXIT register (0 = pass). +max_cycles=<n> bounds
  // the run (default 2,000,000); reaching it is a failure. +stop_at=<cycle>
  // ends the run cleanly at that cycle instead (for a short traced window).
  initial begin
    longint unsigned max_cycles, stop_at;
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 2_000_000;
    if ($value$plusargs("stop_at=%d", stop_at)) begin
      while (!img_exit_valid && (mon_cycle_q < stop_at)) @(posedge clk_i);
      if (!img_exit_valid) begin
        $display("PROGRAM STOPPED at cyc=%0d (+stop_at; not a pass/fail result)", mon_cycle_q);
        $finish;
      end
    end
    while (!img_exit_valid && (mon_cycle_q < max_cycles)) @(posedge clk_i);
    if (!img_exit_valid)
      $fatal(1, "PROGRAM TIMEOUT: no EXIT write within %0d cycles", max_cycles);
    $display("PROGRAM EXIT code=%0d (0x%08h) at cyc=%0d", img_exit_code, img_exit_code, mon_cycle_q);
    if (img_exit_code != 0)
      $fatal(1, "PROGRAM FAILED: exit code 0x%08h", img_exit_code);
    $finish;
  end
`elsif MX_STREAM_TEST
  localparam int unsigned STREAM_RUN_CYCLES = 1500;

  initial begin
    repeat (STREAM_RUN_CYCLES) @(posedge clk_i);
    $display("STREAM RUN COMPLETE after %0d cycles (scoreboard not used in this build)", STREAM_RUN_CYCLES);
    $finish;
  end
`else
  initial begin
    repeat (TIMEOUT_CYCLES) @(posedge clk_i);
    if (sb_state != SB_DONE) begin
      $display("=====================================================");
      $display(" FAIL: TIMEOUT after %0d cycles - scoreboard stuck in %s",
                TIMEOUT_CYCLES, sb_state.name());
      $display("=====================================================");
      fail_count++;
    end
    $display("Summary: pass=%0d fail=%0d", pass_count, fail_count);

    // $fatal (unlike $display+$finish) makes Verilator - and most other
    // simulators - exit with a non-zero process status. That's what lets
    // `make`/CI actually see a scoreboard failure: verilator_tb.cpp does not
    // (and should not need to) reach into this module's internal signals to
    // find out whether the test passed.
    if (fail_count != 0)
      $fatal(1, "Test FAILED (%0d failure(s))", fail_count);
    else
      $finish;
  end
`endif

  //----------------------------------------------------------------------------
  // Passive XIF monitor - measurement only, drives nothing.
  //
  // Prints one "[XIFMON]" line per issue / commit / result handshake, sampled
  // on the same rising edge (pre-edge values) the scoreboard's capture latches
  // above use. Timing is a cycle count, not $time: mon_cycle_q reads 0 on the
  // first rising edge after rst_ni is released and +1 on every edge after.
  // It only reads the xif_* taps above; no scoreboard state or check uses it.
  //----------------------------------------------------------------------------

  // (mon_cycle_q is declared next to clk_i/rst_ni at the top - mem_model's
  // MARK register reads it too.)

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) mon_cycle_q <= '0;
    else         mon_cycle_q <= mon_cycle_q + 1;
  end

  // Mnemonic from funct3/funct2 (encodings: mxdotp_pkg.sv). For MXFP8 under
  // mxfused, rs3[48] picks E4M3 (0) / E5M2 (1).
  function automatic string mon_instr_name(input logic [31:0] instr, input logic fp8_e5m2);
    if (instr[6:0] != mxdotp_pkg::MX_OPCODE) return "non-MX";
    case (instr[14:12])
      mxdotp_pkg::MX_FUNCT3_FUSED:
        case (instr[26:25])
          mxdotp_pkg::MX_FMT_MXFP4:  return "mxfused.mxfp4";
          mxdotp_pkg::MX_FMT_M2XFP4: return "mxfused.m2xfp4";
          mxdotp_pkg::MX_FMT_MXFP8:  return fp8_e5m2 ? "mxfused.mxfp8.e5m2" : "mxfused.mxfp8.e4m3";
          default:                   return "mxfused.fmt01";
        endcase
      mxdotp_pkg::MX_FUNCT3_DOTP:          return "mxresdot";
      mxdotp_pkg::MX_FUNCT3_FINAL:         return "mxfinal";
      mxdotp_pkg::MX_FUNCT3_DUALREAD_TEST: return "mxdualread_test";
      default:                             return "mx.unknown";
    endcase
  endfunction

  // Long program-image runs would print thousands of lines, so there the
  // monitor is off unless +xifmon is given. Every other build: always on.
`ifdef MX_PROGRAM_IMAGE
  bit mon_print_en;
  initial mon_print_en = $test$plusargs("xifmon");
`else
  localparam bit mon_print_en = 1'b1;
`endif

  always @(posedge clk_i) begin
    if (rst_ni && mon_print_en) begin
      // Only an accepted handshake is an issue. A rejected one (the core then
      // treats the instruction as illegal) is printed under its own label so
      // it is never counted as an ISSUE.
      if (xif_issue_valid && xif_issue_ready && xif_issue_accept)
        $display("[XIFMON] cyc=%0d ISSUE  id=%0d %s f3=%03b f2=%02b rd=x%0d",
                 mon_cycle_q, xif_issue_id, mon_instr_name(xif_issue_instr, xif_issue_rs2_wide[48]),
                 xif_issue_instr[14:12], xif_issue_instr[26:25], xif_issue_instr[11:7]);
      else if (xif_issue_valid && xif_issue_ready)
        $display("[XIFMON] cyc=%0d REJECTED-ISSUE id=%0d instr=0x%08h",
                 mon_cycle_q, xif_issue_id, xif_issue_instr);
      if (xif_commit_valid)
        $display("[XIFMON] cyc=%0d COMMIT id=%0d kill=%0b", mon_cycle_q, xif_commit_id, xif_commit_kill);
      if (xif_result_valid && xif_result_ready)
        $display("[XIFMON] cyc=%0d RESULT id=%0d rd=x%0d we=%0b data=0x%08h",
                 mon_cycle_q, xif_result_id, xif_result_rd, xif_result_we, xif_result_data);
    end
  end

  //----------------------------------------------------------------------------
  // Waveform dump (VCD - portable across simulators; use a simulator-native
  // wave config for the grouped Issue/Commit/Result/FSM/WB view during
  // interactive runs)
  //
  // Under Verilator, verilator_tb.cpp already writes tb_mxdotp_core.vcd through
  // VerilatedVcdC. Opening the same file here as well gave two writers and an
  // interleaved, unreadable trace, so this block is for other simulators only.
  //----------------------------------------------------------------------------

`ifndef VERILATOR
  initial begin
    $dumpfile("tb_mxdotp_core.vcd");
    $dumpvars(0, tb_mxdotp_core);
  end
`endif

endmodule
