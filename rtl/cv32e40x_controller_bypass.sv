// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Matthias Baer - baermatt@student.ethz.ch                   //
//                                                                            //
// Additional contributions by:                                               //
//                 Igor Loi - igor.loi@unibo.it                               //
//                 Andreas Traber - atraber@student.ethz.ch                   //
//                 Sven Stucki - svstucki@student.ethz.ch                     //
//                 Michael Gautschi - gautschi@iis.ee.ethz.ch                 //
//                 Davide Schiavone - pschiavo@iis.ee.ethz.ch                 //
//                 Robert Balas - balasr@iis.ee.ethz.ch                       //
//                 Andrea Bettati - andrea.bettati@studenti.unipr.it          //
//                 Halfdan Bechmann - halfdan.bechmann@silabs.com             //
//                 Øystein Knauserud - oystein.knauserud@silabs.com           //
//                                                                            //
// Design Name:    cv32e40x_controller_bypass                                 //
// Project Name:   CV32E40X                                                   //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Bypass logic, hazard detection and stall control           //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cv32e40x_controller_bypass import cv32e40x_pkg::*;
#(
  parameter int unsigned REGFILE_NUM_READ_PORTS = 2
)
(
  // From decoder
  input  logic [REGFILE_NUM_READ_PORTS-1:0]     rf_re_id_i, // Read enables from decoder
  input rf_addr_t     rf_raddr_id_i[REGFILE_NUM_READ_PORTS],// Read addresses from decoder

  // Pipeline registers
  input if_id_pipe_t  if_id_pipe_i,
  input id_ex_pipe_t  id_ex_pipe_i,
  input ex_wb_pipe_t  ex_wb_pipe_i,

  // From ID
  input  logic        alu_en_raw_id_i,            // ALU enable (not gated with deassert) // todo: study area and functional impact of using alu_en_id_i instead
  input  logic        alu_jmpr_id_i,              // ALU jump register (JALR)
  input  logic        sys_en_id_i,
  input  logic        sys_mret_id_i,              // mret in ID
  input  logic        csr_en_id_i,                // CSR in ID
  input  csr_opcode_e csr_op_id_i,                // CSR opcode (ID) // todo: Not used (is this on purpose or should it be used here?)

  // From EX
  input  logic        csr_counter_read_i,         // CSR is reading a counter (EX).

  // From WB
  input  logic        wb_ready_i,                 // WB stage is ready

  // Controller Bypass outputs
  output ctrl_byp_t   ctrl_byp_o
);

  logic [REGFILE_NUM_READ_PORTS-1:0] rf_rd_ex_match;            // Register file address match (ID vs. EX). Not qualified with rf_we_ex yet.
  logic                              rf_rd_ex_jalr_match;
  logic [REGFILE_NUM_READ_PORTS-1:0] rf_rd_wb_match;            // Register file address match (ID vs. WB). Not qualified with rf_we_wb yet.
  logic                              rf_rd_wb_jalr_match;
  logic [REGFILE_NUM_READ_PORTS-1:0] rf_rd_ex_hz;
  logic [REGFILE_NUM_READ_PORTS-1:0] rf_rd_wb_hz;

  // Detect CSR read in ID (implicit and explicit)
  logic csr_read_in_id;

  // Detect CSR write in EX or WB (implicit and explicit)
  logic csr_write_in_ex_wb;

  // EX register file write enable
  logic rf_we_ex;
  assign rf_we_ex = id_ex_pipe_i.rf_we && id_ex_pipe_i.instr_valid;

  // WB register file write enable
  logic rf_we_wb;
  assign rf_we_wb = ex_wb_pipe_i.rf_we && ex_wb_pipe_i.instr_valid;

  // WB lsu_en
  logic lsu_en_wb;
  assign lsu_en_wb = ex_wb_pipe_i.lsu_en && ex_wb_pipe_i.instr_valid;

  // EX rf_waddr
  rf_addr_t  rf_waddr_ex;
  assign rf_waddr_ex = id_ex_pipe_i.rf_waddr;

  // WB rf_waddr
  // TODO: If XIF OoO is allowed, we need to look at WB stage outputs instead
  rf_addr_t  rf_waddr_wb;
  assign rf_waddr_wb = ex_wb_pipe_i.rf_waddr;

  // todo: make all qualifiers here, and use those signals later in the file

  /////////////////////////////////////////////////////////////
  //  ____  _        _ _    ____            _             _  //
  // / ___|| |_ __ _| | |  / ___|___  _ __ | |_ _ __ ___ | | //
  // \___ \| __/ _` | | | | |   / _ \| '_ \| __| '__/ _ \| | //
  //  ___) | || (_| | | | | |__| (_) | | | | |_| | | (_) | | //
  // |____/ \__\__,_|_|_|  \____\___/|_| |_|\__|_|  \___/|_| //
  //                                                         //
  /////////////////////////////////////////////////////////////

  //TODO:OK:low This CSR stall check is very restrictive
  //         Should only check EX vs WB, and also CSR/rd addr
  //         Also consider whether ID or EX should be stalled
  // Detect when a CSR insn is in ID
  // Note that hazard detection uses the registered instr_valid signals. Usage of the local
  // instr_valid signals would lead to a combinatorial loop via the halt signal.

  // todo:low:Above loop reasoning only applies to halt_id; for other pipeline stages a local instr_valid signal can maybe be used.

  assign csr_read_in_id = (csr_en_id_i || (sys_en_id_i && sys_mret_id_i)) && if_id_pipe_i.instr_valid;

  // Detect when a CSR insn  in in EX or WB
  // mret and dret implicitly writes to CSR. (dret is killing IF/ID/EX once it is in WB and can be disregarded here.
  assign csr_write_in_ex_wb = (
                              (id_ex_pipe_i.instr_valid && (id_ex_pipe_i.csr_en || (id_ex_pipe_i.sys_en && id_ex_pipe_i.sys_mret_insn))) ||
                              (ex_wb_pipe_i.instr_valid && (ex_wb_pipe_i.csr_en || (ex_wb_pipe_i.sys_en && ex_wb_pipe_i.sys_mret_insn)))
                              );

  // Stall ID when WFI is active in EX.
  // Prevent load/store following a WFI in the pipeline
  assign ctrl_byp_o.wfi_stall = (id_ex_pipe_i.sys_en && id_ex_pipe_i.sys_wfi_insn && id_ex_pipe_i.instr_valid);

  genvar i;
  generate
    for(i=0; i<REGFILE_NUM_READ_PORTS; i++) begin : gen_forward_signals
      // Does register file read address match write address in EX (excluding R0)?
      assign rf_rd_ex_match[i] = (rf_waddr_ex == rf_raddr_id_i[i]) && |rf_raddr_id_i[i] && rf_re_id_i[i];

      // Does register file read address match write address in WB (excluding R0)?
      assign rf_rd_wb_match[i] = (rf_waddr_wb == rf_raddr_id_i[i]) && |rf_raddr_id_i[i] && rf_re_id_i[i];

      // Load-read hazard (for any instruction following a load)
      assign rf_rd_ex_hz[i] = rf_rd_ex_match[i];
      assign rf_rd_wb_hz[i] = rf_rd_wb_match[i];
    end
  endgenerate

  // JALR rs1 match (rf_re_id_i[0] implied by alu_jmpr_id_i).
  // Not qualified yet with JALR (alu_jmpr_id_i && alu_en_raw_id_i) nor with read enable (implied by JALR)
  assign rf_rd_ex_jalr_match = (rf_waddr_ex == rf_raddr_id_i[0]) && |rf_raddr_id_i[0];
  assign rf_rd_wb_jalr_match = (rf_waddr_wb == rf_raddr_id_i[0]) && |rf_raddr_id_i[0];

  always_comb
  begin
    ctrl_byp_o.load_stall          = 1'b0;
    ctrl_byp_o.deassert_we         = 1'b0;
    ctrl_byp_o.csr_stall           = 1'b0;
    ctrl_byp_o.minstret_stall      = 1'b0;

    // deassert WE when the core has an exception in ID (ins converted to nop and propagated to WB)
    // Also deassert for trigger match, as with dcsr.timing==0 we do not execute before entering debug mode
    if (if_id_pipe_i.instr.bus_resp.err || !(if_id_pipe_i.instr.mpu_status == MPU_OK) || if_id_pipe_i.trigger_match) begin
      ctrl_byp_o.deassert_we = 1'b1;
    end

    // Stall because of load or XIF operation
    if (
        ((id_ex_pipe_i.lsu_en || id_ex_pipe_i.xif_en) && rf_we_ex && |rf_rd_ex_hz) || // load-use hazard (EX)
        (!wb_ready_i                                  && rf_we_wb && |rf_rd_wb_hz)    // load-use hazard (WB during wait-state)
       )
    begin
      ctrl_byp_o.load_stall  = 1'b1;
    end

    // Stall because of jalr path. Stall if a result is to be forwarded to the PC except if result from WB is an ALU result.
    // No need to deassert anything in ID as ID stage is stalled anyway. alu_jmpr_id_i implies rf_re_id_i[0].
    if (alu_jmpr_id_i && alu_en_raw_id_i && ((rf_we_wb && rf_rd_wb_jalr_match && lsu_en_wb) || (rf_we_ex && rf_rd_ex_jalr_match))) begin
      ctrl_byp_o.jalr_stall = 1'b1;
    end else begin
      ctrl_byp_o.jalr_stall = 1'b0;
    end

    // Stall because of CSR read (direct or implied) in ID while CSR (implied or direct) is written in EX/WB
    if (csr_read_in_id && csr_write_in_ex_wb) begin
      ctrl_byp_o.csr_stall = 1'b1;
    end

    // Stall (EX) due to performance counter read
    // csr_counter_read_i is derived from csr_raddr, which is gated with id_ex_pipe.csr_en and id_ex_pipe.instr_valid
    if (csr_counter_read_i && ex_wb_pipe_i.instr_valid) begin
      ctrl_byp_o.minstret_stall = 1'b1;
    end
  end

  // Forwarding control unit
  always_comb
  begin
    // default assignements
    ctrl_byp_o.operand_a_fw_mux_sel = SEL_REGFILE;
    ctrl_byp_o.operand_b_fw_mux_sel = SEL_REGFILE;
    ctrl_byp_o.jalr_fw_mux_sel      = SELJ_REGFILE;

    // Forwarding WB -> ID
    if (rf_we_wb) begin
      if (rf_rd_wb_match[0]) begin
        ctrl_byp_o.operand_a_fw_mux_sel = SEL_FW_WB;
      end
      if (rf_rd_wb_match[1]) begin
        ctrl_byp_o.operand_b_fw_mux_sel = SEL_FW_WB;
      end
    end

    // Forwarding EX -> ID (not actually used when there is a load in EX)
    if (rf_we_ex) begin
      if (rf_rd_ex_match[0]) begin
        ctrl_byp_o.operand_a_fw_mux_sel = SEL_FW_EX;
      end
      if (rf_rd_ex_match[1]) begin
        ctrl_byp_o.operand_b_fw_mux_sel = SEL_FW_EX;
      end
    end

    // Forwarding WB->ID for the jump register path
    // Only used if WB is writing back an ALU result. No forwarding for load result because of timing reasons.
    // Non qualified rf_rd_wb_jalr_match is used as it is a don't care if alu_jmpr_id_i = 0 or jalr_stall = 1.
    if (rf_we_wb) begin
      if (rf_rd_wb_jalr_match) begin
        ctrl_byp_o.jalr_fw_mux_sel = SELJ_FW_WB;
      end
    end
  end

  // Stall EX if offloaded instruction in WB may trigger an exception
  assign ctrl_byp_o.xif_exception_stall = ex_wb_pipe_i.xif_en && ex_wb_pipe_i.xif_meta.exception && ex_wb_pipe_i.instr_valid;

  // Stall EX while a load/store is in EX and an offloaded instruction is in WB.
  // The LSU issues from EX regardless of wb_ready: while an offloaded instruction waits in WB for
  // its XIF result, the load/store in EX would re-request every cycle (no "already issued" state),
  // and the outstanding re-requests hold the LSU's ready_1_o (and so wb_ready) low in the cycle the
  // result arrives. result_ready does not depend on wb_ready, so that result would be accepted and
  // lost, and WB would wait forever (MXR4DOT question 10). Halting EX keeps cnt_q at 0, so WB retires
  // the offloaded instruction in its result cycle; the load/store issues in the next cycle.
  // Only pipeline-register bits: no path from data_rvalid/data_gnt/result_valid, and the stall is
  // already set in the load/store's first EX cycle and only falls, so no raised request is withdrawn.
  // Rejected offloads reach WB with xif_en = 0 (kill_xif), so they do not stall.
  // Assumes the coprocessor never uses the XIF memory interface (issue_resp.loadstore = 0, as in
  // mxdotp_xif.sv); an offloaded instruction that itself uses the LSU would need its own analysis.
  assign ctrl_byp_o.xif_lsu_stall = id_ex_pipe_i.lsu_en && id_ex_pipe_i.instr_valid &&
                                    ex_wb_pipe_i.xif_en && ex_wb_pipe_i.instr_valid;

  // Forwarding control unit for rs3 (XIF's 3rd read port, e.g. R4-type instructions).
  //
  // This only exists when REGFILE_NUM_READ_PORTS >= 3 - unlike rs1/rs2 (indices 0/1,
  // always present), rf_rd_ex_match[2]/rf_rd_wb_match[2] are only valid signals in that
  // configuration (they're generated by the generic gen_forward_signals loop above, which
  // already runs for i up to REGFILE_NUM_READ_PORTS-1 - no new hazard-detection signals are
  // needed here, only the mux-select wiring that was previously missing).
  //
  // Note this only covers the two forwarding *sources* (EX and WB) the same way rs1/rs2 do.
  // The case where rs3's producer can't be forwarded at all yet (e.g. it's a load or another
  // XIF instruction still in EX) is already handled by the existing load_stall logic above:
  // rf_rd_ex_hz/rf_rd_wb_hz are also generic across REGFILE_NUM_READ_PORTS, so
  // ((id_ex_pipe_i.lsu_en || id_ex_pipe_i.xif_en) && rf_we_ex && |rf_rd_ex_hz) already ORs in
  // index 2 and stalls ID correctly - that part needed no changes at all.
  generate
    if (REGFILE_NUM_READ_PORTS >= 3) begin : gen_rs3_fw
      always_comb begin
        // default
        ctrl_byp_o.operand_rs3_fw_mux_sel = SEL_REGFILE;

        // Forwarding WB -> ID
        if (rf_we_wb && rf_rd_wb_match[2]) begin
          ctrl_byp_o.operand_rs3_fw_mux_sel = SEL_FW_WB;
        end

        // Forwarding EX -> ID (not actually used when there is a load/xif op in EX - see
        // load_stall above, same as rs1/rs2)
        if (rf_we_ex && rf_rd_ex_match[2]) begin
          ctrl_byp_o.operand_rs3_fw_mux_sel = SEL_FW_EX;
        end
      end
    end else begin : gen_no_rs3_fw
      // No 3rd read port in this configuration - keep the struct field fully driven.
      assign ctrl_byp_o.operand_rs3_fw_mux_sel = SEL_REGFILE;
    end
  endgenerate

  // Forwarding control unit for the dual-read companion ports (rs1+1/rs2+1/rs3+1 - ports
  // 3/4/5, present only when REGFILE_NUM_READ_PORTS == 6, i.e. X_DUALREAD == 1 at the core
  // level). Exactly the same shape as gen_rs3_fw above, just for three more ports -
  // rf_rd_ex_match[3:5]/rf_rd_wb_match[3:5] already exist and are already correctly
  // computed by the fully generic gen_forward_signals loop above (it runs for i up to
  // REGFILE_NUM_READ_PORTS-1 regardless of what REGFILE_NUM_READ_PORTS actually is), so -
  // same as the rs3 case before it - this is purely mux-select wiring, no new hazard-
  // detection signals. The stall case (a companion register's producer not yet
  // forwardable) is likewise already covered by the existing load_stall logic, since
  // rf_rd_ex_hz/rf_rd_wb_hz are equally generic across all 6 ports.
  generate
    if (REGFILE_NUM_READ_PORTS == 6) begin : gen_dualread_fw
      always_comb begin
        // defaults
        ctrl_byp_o.operand_a_hi_fw_mux_sel   = SEL_REGFILE;
        ctrl_byp_o.operand_b_hi_fw_mux_sel   = SEL_REGFILE;
        ctrl_byp_o.operand_rs3_hi_fw_mux_sel = SEL_REGFILE;

        // Forwarding WB -> ID
        if (rf_we_wb) begin
          if (rf_rd_wb_match[3]) ctrl_byp_o.operand_a_hi_fw_mux_sel   = SEL_FW_WB;
          if (rf_rd_wb_match[4]) ctrl_byp_o.operand_b_hi_fw_mux_sel   = SEL_FW_WB;
          if (rf_rd_wb_match[5]) ctrl_byp_o.operand_rs3_hi_fw_mux_sel = SEL_FW_WB;
        end

        // Forwarding EX -> ID
        if (rf_we_ex) begin
          if (rf_rd_ex_match[3]) ctrl_byp_o.operand_a_hi_fw_mux_sel   = SEL_FW_EX;
          if (rf_rd_ex_match[4]) ctrl_byp_o.operand_b_hi_fw_mux_sel   = SEL_FW_EX;
          if (rf_rd_ex_match[5]) ctrl_byp_o.operand_rs3_hi_fw_mux_sel = SEL_FW_EX;
        end
      end
    end else begin : gen_no_dualread_fw
      // No companion ports in this configuration - keep the struct fields fully driven.
      assign ctrl_byp_o.operand_a_hi_fw_mux_sel   = SEL_REGFILE;
      assign ctrl_byp_o.operand_b_hi_fw_mux_sel   = SEL_REGFILE;
      assign ctrl_byp_o.operand_rs3_hi_fw_mux_sel = SEL_REGFILE;
    end
  endgenerate

endmodule // cv32e40x_controller_bypass
