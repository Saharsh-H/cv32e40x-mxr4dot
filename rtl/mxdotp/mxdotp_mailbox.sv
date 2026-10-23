//==============================================================================
// File    : mxdotp_mailbox.sv
// Project : MXDOTP XIF Coprocessor
//------------------------------------------------------------------------------
// Description:
//   DEPTH-entry FIFO carrying MXDOTP's raw p1/p2 to MXFINAL. Moved out of
//   mxdotp_xif.sv unchanged (23 Oct 2026) so the residue pair (mxresdot +
//   mailbox + mxfinal) can be synthesised as one design with exactly the
//   mailbox the coprocessor uses. The protocol, the DEPTH = 4 sizing and the
//   usage rule on a CV32E40X host are documented where it is instantiated
//   (mxdotp_xif.sv, "Mailbox").
//
//   Contract (the caller guarantees both; there is no internal protection):
//     - push_i only when !full_o  (mxdotp_xif.sv: dotp_result_fire);
//     - pop_i  only when valid_o  (mxdotp_xif.sv: final_engine_start).
//   Push and pop in the same cycle leave the count unchanged. head_p1_o /
//   head_p2_o are the oldest entry, valid while valid_o is high. The data
//   array has no reset; only the pointers and the count do.
//==============================================================================

module mxdotp_mailbox
    import mxdotp_pkg::*;
#(
    parameter int DEPTH = 4
)
(
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         push_i,
    input  logic signed [PSUM_WIDTH-1:0] push_p1_i,
    input  logic signed [PSUM_WIDTH-1:0] push_p2_i,
    input  logic                         pop_i,
    output logic                         full_o,
    output logic                         valid_o,
    output logic signed [PSUM_WIDTH-1:0] head_p1_o,
    output logic signed [PSUM_WIDTH-1:0] head_p2_o
);

    typedef struct packed { logic signed [PSUM_WIDTH-1:0] p1, p2; } mailbox_entry_t;
    mailbox_entry_t mailbox_q [0:DEPTH-1];
    logic [$clog2(DEPTH)-1:0] head_ptr, tail_ptr;
    logic [$clog2(DEPTH+1)-1:0] count;

    assign full_o    = (count == DEPTH);
    assign valid_o   = (count != '0);
    assign head_p1_o = mailbox_q[head_ptr].p1;
    assign head_p2_o = mailbox_q[head_ptr].p2;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            head_ptr <= '0; tail_ptr <= '0; count <= '0;
        end else begin
            if (push_i) tail_ptr <= (tail_ptr == DEPTH-1) ? '0 : tail_ptr + 1'b1;
            if (pop_i)  head_ptr <= (head_ptr == DEPTH-1) ? '0 : head_ptr + 1'b1;
            case ({push_i, pop_i})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
            endcase
        end
    end
    always_ff @(posedge clk_i) begin
        if (push_i) begin
            mailbox_q[tail_ptr].p1 <= push_p1_i;
            mailbox_q[tail_ptr].p2 <= push_p2_i;
        end
    end

endmodule
