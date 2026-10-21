//==============================================================================
// File    : mem_model.sv
// Project : MXDOTP XIF Coprocessor - Verification
//------------------------------------------------------------------------------
// Description:
//   Unified instruction + data memory for the program-image build
//   (make loop, MX_PROGRAM_IMAGE). Replaces instr_rom.sv + data_mem_stub.sv in
//   that build only; the default build (make full) still uses those two.
//
//   Map:
//     0x0000_0000 .. MEM_BYTES-1   RAM - code and data, loaded from +image=<file>
//                                  (one 32-bit word per line, $readmemh, word 0
//                                  at address 0; tb/scripts/bin2hex.py makes it)
//     MMIO_BASE + 0x0  EXIT        write: end the run, value = exit code (0 = pass)
//     MMIO_BASE + 0x4  PUTHEX      write: print "[SW] 0x%08h"
//     MMIO_BASE + 0x8  MARK        write: print "[MARK id] cyc=<cycle_i>"
//   Anything else is a testbench error ($fatal). MMIO reads return 0.
//
//   Data addresses are OBI byte addresses: a byte/halfword access carries its
//   own addr[1:0] together with data_be (lanes already aligned to the word by
//   the core's LSU, which also splits word-crossing accesses), so the word is
//   addr[31:2] and data_be selects the bytes. MMIO registers are word-only.
//
//   Timing: the same reset-gated, 1-cycle OBI model as instr_rom.sv and
//   data_mem_stub.sv - grant in the request cycle, rvalid (and data) on the
//   next cycle, err = 0, exokay = 1. A store is written on its grant edge, so a
//   load granted on a later cycle sees it.
//
//   +dwait=<n> (default 0): data-port response latency. Each data access's
//   rvalid (and read data) arrives n cycles later than above; the grant stays
//   immediate and responses stay in order (a small queue holds the ones in
//   flight), so the core may still overlap accesses if it can. The access
//   itself (memory read/write, MMIO effect) still happens on the grant edge.
//   The instruction port is never delayed (as if fetches hit a cache).
//   With n = 0 the behaviour is cycle-for-cycle the original one.
//
//   +dgnt=<n> (default 0): data-port bandwidth limit. After each data grant
//   the next grant is withheld for n cycles, so the port accepts at most one
//   access every n + 1 cycles (the core keeps its request up until granted);
//   rvalid timing relative to the grant is unchanged (+dwait still applies on
//   top if both are given). Instruction port unaffected. n = 0: original
//   behaviour.
//==============================================================================

module mem_model #(
  parameter int unsigned MEM_BYTES = 128 * 1024,  // power of 2
  parameter logic [31:0] MMIO_BASE = 32'h2000_0000
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic [63:0] cycle_i,          // testbench cycle counter, for MARK

  // Instruction port (read only)
  input  logic        instr_req_i,
  output logic        instr_gnt_o,
  output logic        instr_rvalid_o,
  input  logic [31:0] instr_addr_i,
  output logic [31:0] instr_rdata_o,
  output logic        instr_err_o,

  // Data port
  input  logic        data_req_i,
  output logic        data_gnt_o,
  output logic        data_rvalid_o,
  input  logic        data_we_i,
  input  logic [3:0]  data_be_i,
  input  logic [31:0] data_addr_i,
  input  logic [31:0] data_wdata_i,
  output logic [31:0] data_rdata_o,
  output logic        data_err_o,
  output logic        data_exokay_o,

  // EXIT, to the testbench watchdog
  output logic        exit_valid_o,
  output logic [31:0] exit_code_o
);

  localparam int unsigned NUM_WORDS = MEM_BYTES / 4;
  localparam int unsigned AW        = $clog2(NUM_WORDS);

  localparam logic [31:0] MMIO_EXIT   = MMIO_BASE + 32'h0;
  localparam logic [31:0] MMIO_PUTHEX = MMIO_BASE + 32'h4;
  localparam logic [31:0] MMIO_MARK   = MMIO_BASE + 32'h8;

  logic [31:0] mem [0:NUM_WORDS-1];

  initial begin
    string image;
    for (int unsigned i = 0; i < NUM_WORDS; i++) mem[i] = '0;
    if (!$value$plusargs("image=%s", image))
      $fatal(1, "mem_model: no +image=<file> given");
    $readmemh(image, mem);
    $display("mem_model: loaded %s (%0d KB RAM, MMIO at 0x%08h)", image, MEM_BYTES / 1024, MMIO_BASE);
  end

  function automatic logic in_ram(input logic [31:0] addr);
    return addr < MEM_BYTES;
  endfunction

  //----------------------------------------------------------------------------
  // Instruction port
  //----------------------------------------------------------------------------
  logic        instr_rvalid_q;
  logic [31:0] instr_rdata_q;

  assign instr_gnt_o = rst_ni & instr_req_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instr_rvalid_q <= 1'b0;
      instr_rdata_q  <= '0;
    end else begin
      instr_rvalid_q <= instr_req_i && instr_gnt_o;
      if (instr_req_i && instr_gnt_o) begin
        if (!in_ram(instr_addr_i) || (instr_addr_i[1:0] != 2'b00))
          $fatal(1, "mem_model: instruction fetch outside RAM or misaligned: 0x%08h", instr_addr_i);
        instr_rdata_q <= mem[instr_addr_i[AW+1:2]];
      end
    end
  end

  assign instr_rvalid_o = instr_rvalid_q;
  assign instr_rdata_o  = instr_rdata_q;
  assign instr_err_o    = 1'b0;

  //----------------------------------------------------------------------------
  // Data port + MMIO
  //----------------------------------------------------------------------------
  localparam int unsigned DQ_DEPTH = 4;   // responses in flight; the LSU keeps far fewer outstanding

  int unsigned dwait, dgnt;
  initial begin
    if (!$value$plusargs("dwait=%d", dwait)) dwait = 0;
    if (!$value$plusargs("dgnt=%d", dgnt)) dgnt = 0;
    if (dwait != 0)
      $display("mem_model: data-port response latency +%0d cycle(s) per access (+dwait); instruction port ideal", dwait);
    if (dgnt != 0)
      $display("mem_model: data port accepts at most one access every %0d cycles (+dgnt=%0d); instruction port ideal", dgnt + 1, dgnt);
  end

  int unsigned gnt_hold;                  // cycles left before the next data grant (+dgnt)

  logic [31:0] dq_data [DQ_DEPTH];        // response data, in grant order
  int unsigned dq_wait [DQ_DEPTH];        // cycles until that response may be given
  logic [$clog2(DQ_DEPTH)-1:0] dq_head, dq_tail;
  logic [$clog2(DQ_DEPTH+1)-1:0] dq_count;
  wire  dq_pop = (dq_count != '0) && (dq_wait[dq_head] == 0);   // = rvalid this cycle

  logic        exit_valid_q;
  logic [31:0] exit_code_q;

  assign data_gnt_o = rst_ni & data_req_i & (gnt_hold == 0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dq_head      <= '0;
      dq_tail      <= '0;
      dq_count     <= '0;
      for (int q = 0; q < DQ_DEPTH; q++) begin
        dq_data[q] <= '0;
        dq_wait[q] <= 0;
      end
      exit_valid_q <= 1'b0;
      exit_code_q  <= '0;
      gnt_hold     <= 0;
    end else begin
      // +dgnt: a grant blocks the next dgnt cycles
      if (data_req_i && data_gnt_o) gnt_hold <= dgnt;
      else if (gnt_hold != 0)       gnt_hold <= gnt_hold - 1;

      // age every queued response by one cycle (a push below overrides its slot)
      for (int q = 0; q < DQ_DEPTH; q++)
        if (dq_wait[q] != 0) dq_wait[q] <= dq_wait[q] - 1;
      if (dq_pop) dq_head <= dq_head + 1'b1;
      dq_count <= dq_count + ((data_req_i && data_gnt_o) ? 1 : 0) - (dq_pop ? 1 : 0);

      if (data_req_i && data_gnt_o) begin
        assert (dq_count < DQ_DEPTH || dq_pop)
          else $fatal(1, "mem_model: more than %0d data responses in flight", DQ_DEPTH);
        dq_wait[dq_tail] <= dwait;
        dq_data[dq_tail] <= '0;
        dq_tail          <= dq_tail + 1'b1;
        if (in_ram(data_addr_i)) begin
          if (data_we_i) begin
            for (int b = 0; b < 4; b++)
              if (data_be_i[b]) mem[data_addr_i[AW+1:2]][8*b +: 8] <= data_wdata_i[8*b +: 8];
          end else begin
            dq_data[dq_tail] <= mem[data_addr_i[AW+1:2]];
          end
        end else if ((data_addr_i >= MMIO_BASE) && (data_addr_i < MMIO_BASE + 32'hC) &&
                     ((data_addr_i[1:0] != 2'b00) || (data_be_i != 4'hF))) begin
          $fatal(1, "mem_model: MMIO is word access only (addr 0x%08h, be %b)", data_addr_i, data_be_i);
        end else if (data_we_i && (data_addr_i == MMIO_EXIT)) begin
          exit_valid_q <= 1'b1;
          exit_code_q  <= data_wdata_i;
        end else if (data_we_i && (data_addr_i == MMIO_PUTHEX)) begin
          $display("[SW] 0x%08h", data_wdata_i);
        end else if (data_we_i && (data_addr_i == MMIO_MARK)) begin
          $display("[MARK %0d] cyc=%0d", data_wdata_i, cycle_i);
        end else if (!data_we_i && (data_addr_i >= MMIO_BASE) && (data_addr_i < MMIO_BASE + 32'hC)) begin
          dq_data[dq_tail] <= '0;
        end else begin
          $fatal(1, "mem_model: data %s outside RAM/MMIO at 0x%08h", data_we_i ? "store" : "load", data_addr_i);
        end
      end
    end
  end

  assign data_rvalid_o = dq_pop;
  assign data_rdata_o  = dq_data[dq_head];
  assign data_err_o    = 1'b0;
  assign data_exokay_o = 1'b1;

  assign exit_valid_o  = exit_valid_q;
  assign exit_code_o   = exit_code_q;

endmodule
