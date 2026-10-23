//==============================================================================
// File    : mxdotp_xif.sv
// Project : MXDOTP XIF Coprocessor
//------------------------------------------------------------------------------
// Description:
//   Top-level MXDOTP coprocessor implementing the CORE-V XIF interface.
//
//   Pipelined (see mxdotp_pkg.sv's "pipelined coprocessor" milestone header
//   for the full rationale): MXDOTP, MXFINAL, MX_FUNCT3_DUALREAD_TEST, and
//   MXFUSED each have their own independent slot - own saved-operand/id/rd
//   tracking, own execute engine - instead of one shared FSM/engine for all
//   of them. This replaces the earlier single-in-flight design (issue_ready
//   asserted only in one shared MX_IDLE), which was a real, measured
//   throughput cost, not a theoretical one, and was never required by the
//   XIF protocol itself - every channel (issue_req/commit/result) in
//   if_xif.sv already carries an id field specifically to let multiple
//   offloaded instructions be outstanding at once.
//
//   MILESTONE (current): true overlap for MXDOTP, MXFINAL, AND MXFUSED.
//   MXDOTP and MXFINAL each now have their own small pending-commit FIFO
//   (dotp_pending_q / final_pending_q, both MX_*_PENDING_DEPTH=2 below -
//   same structure and rationale as fused_pending_q, holding instructions
//   accepted at issue but not yet resolved by commit) feeding their own
//   newly-pipelined engines (mxdotp_dotp_engine.sv / mxdotp_final_engine.sv
//   - see those files' own headers for the back-end pipelining rationale),
//   each of which can now hold multiple committed instructions
//   simultaneously at different pipeline stages, exactly like
//   mxdotp_fused_engine.sv already did. issue_ready for MXDOTP/MXFINAL now
//   reflects their own pending queue's fullness, not a single-instruction
//   busy bit - the same change FUSED went through in the prior milestone.
//   MX_FUNCT3_DUALREAD_TEST alone remains genuinely single-outstanding,
//   still via the shared mxdotp_state_t FSM (dr_state_q) - it was never
//   part of any throughput milestone and stays at its original, simple
//   fixed-latency implementation.
//
//   KNOWN LIMITATION carried over from before this milestone, now with a
//   larger blast radius: the in-order result queue below (order_q) has no
//   awareness of a kill landing on anything other than whatever is
//   currently at its own head - there is no per-entry id tag, so a killed
//   MXDOTP/MXFINAL/MXFUSED instruction that is NOT order_q's current head
//   (now substantially more likely, since MXDOTP and MXFINAL can each have
//   two outstanding instead of one) silently vanishes from its own pending
//   queue without ever telling order_q to skip it, orphaning that entry.
//   This is believed unreachable in practice: a kill can only reach an
//   already-accepted XIF instruction via kill_ex (confirmed directly
//   against cv32e40x_controller_fsm.sv - a plain taken branch only asserts
//   kill_if/kill_id, never kill_ex), and every event that DOES assert
//   kill_ex (NMI/IRQ/exception-in-WB/fencei/dret) requires something this
//   project's test/benchmark programs deliberately never use (interrupts
//   enabled, an exception, fencei, or debug entry). If that assumption ever
//   changes, order_q needs the same id-tagged tombstone treatment across
//   all three pending queues before kill correctness can be relied on.
//
//   MXDOTP/MXFINAL are RESIDUE-STYLE FORMATS ONLY as of the fused-fast-path
//   milestone (see mxdotp_pkg.sv's MX_SLOT_FUSED milestone header): plain
//   (non-residue) MXFP4/MXFP8 never reach those two slots any more - they go
//   exclusively through the FUSED slot.
//
//   The mailbox carrying MXDOTP's raw p1/p2 to MXFINAL is a MAILBOX_DEPTH=4
//   FIFO (see that section below: the depth bounds how many MXDOTP may run
//   ahead of their MXFINALs before the host deadlocks), not a single entry - it had to stop being
//   single-entry the moment MXDOTP gained more than one outstanding
//   instruction, since a second MXDOTP's result could otherwise arrive
//   before MXFINAL had consumed the first.
//
//   Results are delivered through a small in-order queue (see mx_slot_e/
//   MX_ORDER_DEPTH in mxdotp_pkg.sv): only the oldest still-outstanding
//   instruction's slot may present result_valid, even if a more-recently-
//   issued slot's engine finished computing first. MX_ORDER_DEPTH is now
//   sized for DOTP+FINAL+DUALREAD_TEST (one each, unchanged) PLUS however
//   many FUSED instructions can genuinely be outstanding at once - no
//   longer a flat MX_NUM_SLOTS, since one slot (FUSED) can now contribute
//   many simultaneous entries instead of at most one.
//
//==============================================================================

module mxdotp_xif
    import cv32e40x_pkg::*;
    import mxdotp_pkg::*;
#(
    // Must match the X_ID_WIDTH / X_RFR_WIDTH / X_RFW_WIDTH used to
    // instantiate the if_xif interface this module is connected to. Passed
    // explicitly from the top level (mxdotp_core_top.sv) rather than pulled
    // off the interface instance, so a parameter mismatch shows up as a
    // port-width mismatch at elaboration instead of silently compiling with
    // the interface's values.
    parameter int X_ID_WIDTH  = 4,
    parameter int X_RFR_WIDTH = 32,
    parameter int X_RFW_WIDTH = 32
)
(
    input  logic clk_i,
    input  logic rst_ni,

    //--------------------------------------------------------------------------
    // XIF Interfaces
    //--------------------------------------------------------------------------

    if_xif.coproc_issue      issue_if,
    if_xif.coproc_commit     commit_if,
    if_xif.coproc_result     result_if,
    if_xif.coproc_mem        mem_if,
    if_xif.coproc_mem_result mem_result_if
);

    // Elaboration-time sanity check that the parameters above actually match
    // the interface instance wired in. Simulation-only; synthesis tools that
    // don't like $error in an initial block can strip this between the
    // translate_off/on pragmas.
    // synthesis translate_off
    initial begin
        assert (X_ID_WIDTH == issue_if.X_ID_WIDTH) else
            $error("mxdotp_xif: X_ID_WIDTH (%0d) does not match issue_if.X_ID_WIDTH (%0d)",
                    X_ID_WIDTH, issue_if.X_ID_WIDTH);
        assert (X_RFR_WIDTH == issue_if.X_RFR_WIDTH) else
            $error("mxdotp_xif: X_RFR_WIDTH (%0d) does not match issue_if.X_RFR_WIDTH (%0d)",
                    X_RFR_WIDTH, issue_if.X_RFR_WIDTH);
        assert (X_RFW_WIDTH == result_if.X_RFW_WIDTH) else
            $error("mxdotp_xif: X_RFW_WIDTH (%0d) does not match result_if.X_RFW_WIDTH (%0d)",
                    X_RFW_WIDTH, result_if.X_RFW_WIDTH);
    end
    // synthesis translate_on

    //--------------------------------------------------------------------------
    // Decoder (combinational - decodes whatever instruction is CURRENTLY
    // presented on the issue port, regardless of which slots are busy)
    //--------------------------------------------------------------------------

    logic       is_mx;
    logic [2:0] mx_operation;
    logic [1:0] mx_format;

    logic [4:0] rd;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [4:0] rs3;

    mxdotp_decoder decoder_i (
        .instr        (issue_if.issue_req.instr),
        .is_mx        (is_mx),
        .mx_operation (mx_operation),
        .mx_format    (mx_format),
        .rd           (rd),
        .rs1          (rs1),
        .rs2          (rs2),
        .rs3          (rs3)
    );

    //--------------------------------------------------------------------------
    // Per-slot state registers
    //--------------------------------------------------------------------------

    mxdotp_state_t dr_state_q,    dr_state_d;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dr_state_q    <= MX_IDLE;
        end else begin
            dr_state_q    <= dr_state_d;
        end
    end

    typedef enum logic [1:0] { FUSED_PENDING, FUSED_COMMIT_OK, FUSED_COMMIT_KILL } fused_commit_status_e;

    //--------------------------------------------------------------------------
    // DOTP & FINAL Pending Queues
    //--------------------------------------------------------------------------
    typedef struct packed {
        logic [X_ID_WIDTH-1:0]  id;
        logic [X_RFR_WIDTH-1:0] rs1;
        logic [X_RFR_WIDTH-1:0] rs2;
        logic [X_RFR_WIDTH-1:0] rs3;
        fused_commit_status_e   status;
    } dotp_pending_entry_t;
    
    typedef struct packed {
        logic [X_ID_WIDTH-1:0]  id;
        logic [4:0]             rd;
        logic [X_RFR_WIDTH-1:0] rs1;
        logic [X_RFR_WIDTH-1:0] rs2;
        fused_commit_status_e   status;
    } final_pending_entry_t;

    localparam int MX_DOTP_PENDING_DEPTH = 2;
    dotp_pending_entry_t dotp_pending_q [0:MX_DOTP_PENDING_DEPTH-1];
    logic [$clog2(MX_DOTP_PENDING_DEPTH)-1:0] dotp_pending_head_ptr, dotp_pending_tail_ptr;
    logic [$clog2(MX_DOTP_PENDING_DEPTH+1)-1:0] dotp_pending_count;
    wire dotp_pending_full  = (dotp_pending_count == MX_DOTP_PENDING_DEPTH);
    wire dotp_pending_empty = (dotp_pending_count == '0);

    localparam int MX_FINAL_PENDING_DEPTH = 2;
    final_pending_entry_t final_pending_q [0:MX_FINAL_PENDING_DEPTH-1];
    logic [$clog2(MX_FINAL_PENDING_DEPTH)-1:0] final_pending_head_ptr, final_pending_tail_ptr;
    logic [$clog2(MX_FINAL_PENDING_DEPTH+1)-1:0] final_pending_count;
    wire final_pending_full  = (final_pending_count == MX_FINAL_PENDING_DEPTH);
    wire final_pending_empty = (final_pending_count == '0);

    //--------------------------------------------------------------------------
    // Issue Interface
    //--------------------------------------------------------------------------
    //
    // issue_ready is no longer one shared bit - it reflects whichever slot
    // the CURRENTLY PRESENTED instruction's own mx_operation maps to, so
    // e.g. MXFINAL can be issued (and committed) while a preceding MXDOTP is
    // still computing. Non-MX instructions (is_mx == 0) always see ready=1:
    // they have nothing to do with any of our slots, and must never be
    // stalled by our own busyness.
    //--------------------------------------------------------------------------

    assign issue_if.issue_ready =
        !is_mx                                    ? 1'b1 :
        (mx_operation == MX_FUNCT3_DOTP)           ? !dotp_pending_full :
        (mx_operation == MX_FUNCT3_FINAL)          ? !final_pending_full :
        (mx_operation == MX_FUNCT3_DUALREAD_TEST)  ? (dr_state_q    == MX_IDLE) :
        (mx_operation == MX_FUNCT3_FUSED)          ? !fused_pending_full :
        1'b1;

    always_comb begin
        issue_if.issue_resp = '0;

        // dualread is a pure function of instruction encoding (mx_operation,
        // itself decoded from issue_req.instr alone by mxdotp_decoder, whose
        // ONLY input is instr - see decoder_i above). Computed unconditionally
        // here, NOT gated on issue_valid/issue_ready like its sibling fields
        // below, so it has zero dependency on anything downstream of the
        // issue handshake and cannot participate in a combinational cycle
        // back through issue_valid. This was previously computed inside the
        // gated block below (identical expression), which created exactly
        // that cycle: issue_resp.dualread -> cv32e40x_id_stage.sv's
        // rf_re_o[5:3]/issue_req.rs[0:2] -> controller_bypass.sv hazard
        // logic -> controller_fsm.sv stall decision -> instr_valid ->
        // issue_valid -> back into this always_comb block. Confirmed by two
        // independent tools (Yosys post-flatten CHECK, Verilator UNOPTFLAT)
        // and traced end-to-end through the actual RTL. The truth table is
        // UNCHANGED (still 1 for DOTP/DUALREAD_TEST/FUSED, 0 for FINAL) -
        // only WHEN it's computed changed, not WHAT it means. Per the
        // CV-X-IF spec's own wording ("signals in issue_resp are valid when
        // issue_valid and issue_ready are both 1 - there are no stability
        // requirements"), that's a floor on what a consumer may rely on, not
        // a ceiling on when the coprocessor may compute the real value.
        issue_if.issue_resp.dualread = is_mx && ((mx_operation == MX_FUNCT3_DOTP) ||
                                                  (mx_operation == MX_FUNCT3_DUALREAD_TEST) ||
                                                  (mx_operation == MX_FUNCT3_FUSED));

        if (issue_if.issue_valid && is_mx && issue_if.issue_ready) begin
            issue_if.issue_resp.accept = 1'b1;
            // MXDOTP stages its raw dot-product sums in the mailbox and does
            // not touch rd; MXFINAL and MXFUSED (which each apply the MX
            // scale(s) and combine with an old FP32 accumulator) produce an
            // architectural result. This is checked against
            // cv32e40x_id_stage.sv: issue_resp.writeback drives xif_we,
            // which feeds rf_we = rf_we_dec || xif_we and flows straight
            // through to rf_we_wb_o in the WB stage - so setting it to 0
            // here genuinely suppresses the register write. (dualwrite is
            // still a dead field in this checkout - only dualread now has a
            // real consumer, see below - so dualwrite is left at its
            // default 0 for every MX op; MXFINAL/MXFUSED only ever write a
            // single FP32 word, never a register pair.)
            issue_if.issue_resp.writeback = (mx_operation == MX_FUNCT3_FINAL) ||
                                             (mx_operation == MX_FUNCT3_DUALREAD_TEST) ||
                                             (mx_operation == MX_FUNCT3_FUSED);
            // MXDOTP's rs1/rs2/rs3 (A/B/AR) are ALWAYS 64-bit dual-read (now
            // exclusively for residue-style formats - see mxdotp_pkg.sv's
            // MX_SLOT_FUSED milestone header). MXFINAL's rs1/rs2
            // (scales/old_acc) are conversely NEVER dual-read. MXFUSED also
            // dual-reads all three of its operands: rs1=A, rs2=B (same
            // shape as MXDOTP's) and rs3={scales,old_acc} (packed like
            // MXFINAL's rs1 is today, just relocated and dual-read since it
            // now needs the full 64 bits). MX_FUNCT3_DUALREAD_TEST also
            // requests it, independent of format, for its own validation
            // purpose (see mxdotp_pkg.sv). dualread itself is now assigned
            // unconditionally above - see that comment for why.
        end
    end

    // Acceptance pulses - each is high for exactly the one cycle a given
    // slot's instruction is accepted at issue. Mutually exclusive by
    // construction (mx_operation is a single decoded value).
    logic accept_dotp, accept_final, accept_dr, accept_fused;
    assign accept_dotp  = issue_if.issue_valid && issue_if.issue_ready && is_mx && (mx_operation == MX_FUNCT3_DOTP);
    assign accept_final = issue_if.issue_valid && issue_if.issue_ready && is_mx && (mx_operation == MX_FUNCT3_FINAL);
    assign accept_dr    = issue_if.issue_valid && issue_if.issue_ready && is_mx && (mx_operation == MX_FUNCT3_DUALREAD_TEST);
    assign accept_fused = issue_if.issue_valid && issue_if.issue_ready && is_mx && (mx_operation == MX_FUNCT3_FUSED);

    //--------------------------------------------------------------------------
    // Saved instruction registers - one independent set per slot
    //--------------------------------------------------------------------------

    

    

    // MX_FUNCT3_DUALREAD_TEST: rs1=base register only (rs2/rs3 are read per
    // the interface's global dualread bit but never looked at - see
    // mxdotp_pkg.sv).
    logic [X_ID_WIDTH-1:0]  dr_saved_id;
    logic [4:0]             dr_saved_rd;
    logic [X_RFR_WIDTH-1:0] dr_saved_rs1;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dr_saved_id  <= '0;
            dr_saved_rd  <= '0;
            dr_saved_rs1 <= '0;
        end else if (accept_dr) begin
            dr_saved_id  <= issue_if.issue_req.id;
            dr_saved_rd  <= rd;
            dr_saved_rs1 <= issue_if.issue_req.rs[0];
        end
    end

    
    // DOTP Queue Control
    wire dotp_pending_head_valid = !dotp_pending_empty;
    wire dotp_pending_head_committed_now = dotp_pending_head_valid && commit_if.commit_valid && (commit_if.commit.id == dotp_pending_q[dotp_pending_head_ptr].id) && (dotp_pending_q[dotp_pending_head_ptr].status == FUSED_PENDING);
    wire dotp_pending_head_ok = dotp_pending_head_valid && ((dotp_pending_q[dotp_pending_head_ptr].status == FUSED_COMMIT_OK) || (dotp_pending_head_committed_now && !commit_if.commit.commit_kill));
    wire dotp_pending_head_kill = dotp_pending_head_valid && ((dotp_pending_q[dotp_pending_head_ptr].status == FUSED_COMMIT_KILL) || (dotp_pending_head_committed_now && commit_if.commit.commit_kill));
    
    wire dotp_pending_push = accept_dotp;
    wire dotp_engine_start, dotp_engine_ready;
    wire dotp_pending_pop = dotp_pending_head_kill || dotp_engine_start;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dotp_pending_head_ptr <= '0; dotp_pending_tail_ptr <= '0; dotp_pending_count <= '0;
        end else begin
            if (dotp_pending_push) dotp_pending_tail_ptr <= (dotp_pending_tail_ptr == MX_DOTP_PENDING_DEPTH-1) ? '0 : dotp_pending_tail_ptr + 1'b1;
            if (dotp_pending_pop) dotp_pending_head_ptr <= (dotp_pending_head_ptr == MX_DOTP_PENDING_DEPTH-1) ? '0 : dotp_pending_head_ptr + 1'b1;
            case ({dotp_pending_push, dotp_pending_pop})
                2'b10: dotp_pending_count <= dotp_pending_count + 1'b1;
                2'b01: dotp_pending_count <= dotp_pending_count - 1'b1;
            endcase
        end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
        end else begin
            if (dotp_pending_push) begin
                // synthesis translate_off
                assert (!dotp_pending_full) else
                    $error("mxdotp_xif: DOTP pending-commit queue overflowed (depth=%0d) - MX_DOTP_PENDING_DEPTH here in mxdotp_xif.sv is too small for this workload's actual issue-to-commit latency; deepen it, don't silently overwrite.",
                            MX_DOTP_PENDING_DEPTH);
                // synthesis translate_on
                dotp_pending_q[dotp_pending_tail_ptr].id <= issue_if.issue_req.id;
                dotp_pending_q[dotp_pending_tail_ptr].rs1 <= issue_if.issue_req.rs[0];
                dotp_pending_q[dotp_pending_tail_ptr].rs2 <= issue_if.issue_req.rs[1];
                dotp_pending_q[dotp_pending_tail_ptr].rs3 <= issue_if.issue_req.rs[2];
                dotp_pending_q[dotp_pending_tail_ptr].status <= FUSED_PENDING;
            end
            if (dotp_pending_head_committed_now && !dotp_pending_pop) begin
                dotp_pending_q[dotp_pending_head_ptr].status <= commit_if.commit.commit_kill ? FUSED_COMMIT_KILL : FUSED_COMMIT_OK;
            end
        end
    end

    // FINAL Queue Control
    wire final_pending_head_valid = !final_pending_empty;
    wire final_pending_head_committed_now = final_pending_head_valid && commit_if.commit_valid && (commit_if.commit.id == final_pending_q[final_pending_head_ptr].id) && (final_pending_q[final_pending_head_ptr].status == FUSED_PENDING);
    wire final_pending_head_ok = final_pending_head_valid && ((final_pending_q[final_pending_head_ptr].status == FUSED_COMMIT_OK) || (final_pending_head_committed_now && !commit_if.commit.commit_kill));
    wire final_pending_head_kill = final_pending_head_valid && ((final_pending_q[final_pending_head_ptr].status == FUSED_COMMIT_KILL) || (final_pending_head_committed_now && commit_if.commit.commit_kill));

    wire final_pending_push = accept_final;
    wire final_engine_start, final_engine_ready;
    wire final_pending_pop = final_pending_head_kill || final_engine_start;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            final_pending_head_ptr <= '0; final_pending_tail_ptr <= '0; final_pending_count <= '0;
        end else begin
            if (final_pending_push) final_pending_tail_ptr <= (final_pending_tail_ptr == MX_FINAL_PENDING_DEPTH-1) ? '0 : final_pending_tail_ptr + 1'b1;
            if (final_pending_pop) final_pending_head_ptr <= (final_pending_head_ptr == MX_FINAL_PENDING_DEPTH-1) ? '0 : final_pending_head_ptr + 1'b1;
            case ({final_pending_push, final_pending_pop})
                2'b10: final_pending_count <= final_pending_count + 1'b1;
                2'b01: final_pending_count <= final_pending_count - 1'b1;
            endcase
        end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
        end else begin
            if (final_pending_push) begin
                // synthesis translate_off
                assert (!final_pending_full) else
                    $error("mxdotp_xif: FINAL pending-commit queue overflowed (depth=%0d) - MX_FINAL_PENDING_DEPTH here in mxdotp_xif.sv is too small for this workload's actual issue-to-commit latency; deepen it, don't silently overwrite.",
                            MX_FINAL_PENDING_DEPTH);
                // synthesis translate_on
                final_pending_q[final_pending_tail_ptr].id <= issue_if.issue_req.id;
                final_pending_q[final_pending_tail_ptr].rd <= rd;
                final_pending_q[final_pending_tail_ptr].rs1 <= issue_if.issue_req.rs[0];
                final_pending_q[final_pending_tail_ptr].rs2 <= issue_if.issue_req.rs[1];
                final_pending_q[final_pending_tail_ptr].status <= FUSED_PENDING;
            end
            if (final_pending_head_committed_now && !final_pending_pop) begin
                final_pending_q[final_pending_head_ptr].status <= commit_if.commit.commit_kill ? FUSED_COMMIT_KILL : FUSED_COMMIT_OK;
            end
        end
    end

    //--------------------------------------------------------------------------
    // FUSED pending-commit queue: holds instructions accepted at issue but
    // not yet resolved by commit (proceed vs kill) - see mxdotp_pkg.sv's
    // MX_FUSED_PENDING_DEPTH milestone comment for sizing rationale, and
    // mxdotp_fused_engine.sv's own header for why this stays a SEPARATE
    // structure from that engine's internal pipeline rather than folded
    // into one: this queue's occupancy time is inherently variable (bounded
    // by however long commit takes to arrive), while the engine's own
    // stages are now fixed-1-cycle-each - mixing the two would reintroduce
    // the non-uniform timing this whole effort has been removing.
    //
    // A plain FIFO, not id-matched per entry: CV32E40X commits strictly in
    // program order, and accept_fused pushes in program order too, so an
    // incoming commit_valid always resolves the CURRENT HEAD entry - never
    // any other entry in the queue. This is why no per-entry id search is
    // needed, only a head-pointer check.
    //--------------------------------------------------------------------------

    

    typedef struct packed {
        logic [X_ID_WIDTH-1:0]  id;
        logic [4:0]             rd;
        logic [1:0]             format;
        logic [X_RFR_WIDTH-1:0] rs1;
        logic [X_RFR_WIDTH-1:0] rs2;
        logic [X_RFR_WIDTH-1:0] rs3;
        fused_commit_status_e   status;
    } fused_pending_entry_t;

    localparam int MX_FUSED_PENDING_PTR_WIDTH =
        (MX_FUSED_PENDING_DEPTH <= 1) ? 1 : $clog2(MX_FUSED_PENDING_DEPTH);
    localparam int MX_FUSED_PENDING_CNT_WIDTH = $clog2(MX_FUSED_PENDING_DEPTH + 1);

    fused_pending_entry_t fused_pending_q [0:MX_FUSED_PENDING_DEPTH-1];
    logic [MX_FUSED_PENDING_PTR_WIDTH-1:0] fused_pending_head_ptr, fused_pending_tail_ptr;
    logic [MX_FUSED_PENDING_CNT_WIDTH-1:0] fused_pending_count;

    wire fused_pending_empty = (fused_pending_count == '0);
    wire fused_pending_full  = (fused_pending_count == MX_FUSED_PENDING_DEPTH);
    wire fused_pending_head_valid = !fused_pending_empty;

    // Resolving fresh THIS cycle (commit_valid arrives for a still-PENDING
    // head) reacts combinationally, same cycle, same low latency the old
    // single-register design had - not delayed a cycle waiting for a
    // registered status update. The registered status field only matters
    // for remembering a resolution that couldn't be immediately handed to
    // the engine (engine not ready that exact cycle) across to a later one.
    wire fused_pending_head_committed_now =
        fused_pending_head_valid && commit_if.commit_valid &&
        (commit_if.commit.id == fused_pending_q[fused_pending_head_ptr].id) &&
        (fused_pending_q[fused_pending_head_ptr].status == FUSED_PENDING);

    wire fused_pending_head_ok =
        fused_pending_head_valid &&
        ((fused_pending_q[fused_pending_head_ptr].status == FUSED_COMMIT_OK) ||
         (fused_pending_head_committed_now && !commit_if.commit.commit_kill));

    wire fused_pending_head_kill =
        fused_pending_head_valid &&
        ((fused_pending_q[fused_pending_head_ptr].status == FUSED_COMMIT_KILL) ||
         (fused_pending_head_committed_now && commit_if.commit.commit_kill));

    // fused_pending_push/pop drive the shared queue's tail/head. The pop
    // condition forward-references the two engines' start signals (defined in
    // the FUSED engine section below); both are pure combinational, so the
    // forward reference is safe - same style already used for order_head_tag.
    wire fused_pending_push = accept_fused;
    // Which engine the head belongs to, by its element format: MXFP8 -> the fp8
    // engine, M2XFP4 -> the m2 engine, everything else (MXFP4 plus the
    // not-meaningful-here MXFP4_RESIDUAL) -> the MXFP4 engine, whose SoP=0
    // stub keeps the residual encoding safe-inert as before.
    wire head_is_fp8 = fused_pending_head_valid &&
                       (fused_pending_q[fused_pending_head_ptr].format == MX_FMT_MXFP8);
    wire head_is_m2  = fused_pending_head_valid &&
                       (fused_pending_q[fused_pending_head_ptr].format == MX_FMT_M2XFP4);
    // fused4/fused8/fusedm2_engine_start are defined in the FUSED engine
    // section below; all are pure combinational (start derives from ready,
    // ready comes straight from an engine instance), so this forward reference
    // is safe - same style already used for order_head_tag elsewhere.
    wire fused_pending_pop  = fused_pending_head_kill ||
                              fused4_engine_start || fused8_engine_start ||
                              fusedm2_engine_start;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            fused_pending_head_ptr <= '0;
            fused_pending_tail_ptr <= '0;
            fused_pending_count    <= '0;
        end else begin
            if (fused_pending_push) begin
                fused_pending_tail_ptr <= (fused_pending_tail_ptr == MX_FUSED_PENDING_DEPTH-1) ?
                                           '0 : fused_pending_tail_ptr + 1'b1;
            end
            if (fused_pending_pop) begin
                fused_pending_head_ptr <= (fused_pending_head_ptr == MX_FUSED_PENDING_DEPTH-1) ?
                                           '0 : fused_pending_head_ptr + 1'b1;
            end
            unique case ({fused_pending_push, fused_pending_pop})
                2'b10:   fused_pending_count <= fused_pending_count + 1'b1;
                2'b01:   fused_pending_count <= fused_pending_count - 1'b1;
                default: fused_pending_count <= fused_pending_count;
            endcase
        end
    end

    integer fp_i;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (fp_i = 0; fp_i < MX_FUSED_PENDING_DEPTH; fp_i++) fused_pending_q[fp_i] <= '0;
        end else begin
            if (fused_pending_push) begin
                // synthesis translate_off
                assert (!fused_pending_full) else
                    $error("mxdotp_xif: FUSED pending-commit queue overflowed (depth=%0d) - MX_FUSED_PENDING_DEPTH in mxdotp_pkg.sv is too small for this workload's actual issue-to-commit latency; deepen it there, not here.",
                            MX_FUSED_PENDING_DEPTH);
                // synthesis translate_on
                fused_pending_q[fused_pending_tail_ptr].id     <= issue_if.issue_req.id;
                fused_pending_q[fused_pending_tail_ptr].rd     <= rd;
                fused_pending_q[fused_pending_tail_ptr].format <= mx_format;
                fused_pending_q[fused_pending_tail_ptr].rs1    <= issue_if.issue_req.rs[0];
                fused_pending_q[fused_pending_tail_ptr].rs2    <= issue_if.issue_req.rs[1];
                fused_pending_q[fused_pending_tail_ptr].rs3    <= issue_if.issue_req.rs[2];
                fused_pending_q[fused_pending_tail_ptr].status <= FUSED_PENDING;
            end
            // Latch a fresh resolution ONLY if it couldn't be handed off to
            // the engine this same cycle (fused_pending_pop already covers
            // the "handed off now" case - see fused_pending_pop above).
            if (fused_pending_head_committed_now && !fused_pending_pop) begin
                fused_pending_q[fused_pending_head_ptr].status <=
                    commit_if.commit.commit_kill ? FUSED_COMMIT_KILL : FUSED_COMMIT_OK;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Mailbox: MAILBOX_DEPTH-entry FIFO carrying MXDOTP's raw p1/p2 to
    // MXFINAL. See file header for the full protocol. RESIDUE-STYLE FORMATS
    // ONLY now - MXFUSED never touches this; it has no cross-instruction
    // hand-off at all (see mxdotp_fused_engine.sv's own internal front-end/
    // back-end register instead).
    //
    // MAILBOX_DEPTH=4 sizing - this IS a correctness bound, not only a
    // throughput knob. (The earlier version of this comment said correctness
    // held for any depth >= 1; that is wrong on an in-order host.)
    //
    // Usage rule (CV32E40X host): at most MAILBOX_DEPTH (4) MXDOTP may be
    // outstanding ahead of the first of their MXFINALs. A (MAILBOX_DEPTH+1)th
    // - the 5th - is safe only if the instruction directly after it is an
    // MXFINAL. Anything more (e.g. 6 consecutive MXDOTP) deadlocks.
    //
    // Why: an MXDOTP result retires into the mailbox and over the XIF result
    // channel on the same edge (dotp_result_fire, below), so the MXDOTP sits
    // in the core's WB stage until the mailbox has space - CV32E40X holds an
    // offloaded instruction in WB until its result arrives. Entries are freed
    // only when an MXFINAL starts, which needs its commit, and CV32E40X only
    // commits the offloaded instruction in EX. With the MXDOTP stuck in WB,
    // the one instruction that can still commit is the one directly behind
    // it: if that is an MXFINAL it pops an entry and the MXDOTP retires; if
    // not, nothing can free space. Every entry already in the mailbox belongs
    // to an older MXDOTP whose MXFINAL is younger than the stalled one (an
    // older MXFINAL would already have retired, so started, so popped).
    // Pair-interleaved code (MXDOTP, MXFINAL, MXDOTP, ...) never has more
    // than one entry in the mailbox.
    //
    // Raising MAILBOX_DEPTH raises the bound one for one. Returning the
    // MXDOTP's XIF result early (at commit, CV-X-IF-legal) would raise it
    // further - the engine pipeline and dotp_pending_q would absorb the
    // overflow - but not remove it: past that, issue_ready for a later MXDOTP
    // would wait on an MXFINAL that is younger still. Analysis 21 Oct 2026;
    // the 5-consecutive case is exercised by make stream (S6).
    //--------------------------------------------------------------------------

    
    localparam int MAILBOX_DEPTH = 4;
    // The FIFO itself is mxdotp_mailbox.sv (moved out unchanged, 23 Oct 2026,
    // so the residue pair can be synthesised with this exact mailbox).
    logic mailbox_full, mailbox_valid_q;
    logic signed [PSUM_WIDTH-1:0] mailbox_p1_q, mailbox_p2_q;
    logic signed [PSUM_WIDTH-1:0] dotp_engine_p1, dotp_engine_p2;
    logic dotp_result_ready_xif;  // driven with the other result-ready gates (order-queue head)

    wire dotp_result_valid;
    logic [X_ID_WIDTH-1:0] dotp_result_id;  // was missing entirely - Verilator was silently
                                             // creating this as an implicit 1-bit net, truncating
                                             // dotp_engine's real X_ID_WIDTH-bit result_id_o down
                                             // to its LSB before it ever reached result_if.result.id
    // A DOTP result retires in ONE step: into the mailbox AND over the XIF
    // result channel, on the same edge. Both conditions are required:
    //   !mailbox_full          - somewhere to put p1/p2;
    //   dotp_result_ready_xif  - the DOTP slot is at the order-queue head and
    //                            the core accepts the result this cycle.
    // Previously the engine retired on !mailbox_full alone, so a DOTP result
    // that completed while an OLDER slot (e.g. the previous pair's FINAL) held
    // the head went into the mailbox and its XIF result was never sent - the
    // core then waited for it in WB forever (back-to-back pairs hung; found by
    // the make-stream measurement, 21 Oct 2026). The engine's global stall
    // holds result_valid until this fires.
    wire dotp_result_fire = dotp_result_valid && !mailbox_full && dotp_result_ready_xif;
    wire mailbox_push = dotp_result_fire;
    wire mailbox_pop = final_engine_start;

    mxdotp_mailbox #(
        .DEPTH (MAILBOX_DEPTH)
    ) mailbox_i (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .push_i    (mailbox_push),
        .push_p1_i (dotp_engine_p1),
        .push_p2_i (dotp_engine_p2),
        .pop_i     (mailbox_pop),
        .full_o    (mailbox_full),
        .valid_o   (mailbox_valid_q),
        .head_p1_o (mailbox_p1_q),
        .head_p2_o (mailbox_p2_q)
    );

    assign dotp_engine_start = dotp_pending_head_ok && dotp_engine_ready;


    mxdotp_dotp_engine #(
        .X_RFR_WIDTH (X_RFR_WIDTH)
    ) dotp_engine_i (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .start_i (dotp_engine_start),
        .ready_o (dotp_engine_ready),
        .result_valid_o (dotp_result_valid),
        .result_ready_i (!mailbox_full && dotp_result_ready_xif),
        .id_i (dotp_pending_q[dotp_pending_head_ptr].id),
        .result_id_o (dotp_result_id),
        .rs1_i (dotp_pending_q[dotp_pending_head_ptr].rs1),
        .rs2_i (dotp_pending_q[dotp_pending_head_ptr].rs2),
        .rs3_i (dotp_pending_q[dotp_pending_head_ptr].rs3),
        .p1_o    (dotp_engine_p1),
        .p2_o    (dotp_engine_p2)
    );

    

    //--------------------------------------------------------------------------
    // FINAL slot: engine, mailbox-read handshake, FSM
    //--------------------------------------------------------------------------

    logic final_result_valid, final_result_ready;
    logic [X_ID_WIDTH-1:0] final_result_id;
    logic [4:0] final_result_rd;
    logic [X_RFW_WIDTH-1:0] final_result_data;
    assign final_engine_start = final_pending_head_ok && mailbox_valid_q && final_engine_ready;

    mxdotp_final_engine #(
        .X_RFR_WIDTH (X_RFR_WIDTH),
        .X_RFW_WIDTH (X_RFW_WIDTH),
        .X_ID_WIDTH  (X_ID_WIDTH)
    ) final_engine_i (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .start_i     (final_engine_start),
        .ready_o     (final_engine_ready),
        .result_valid_o (final_result_valid),
        .result_ready_i (final_result_ready),
        .id_i        (final_pending_q[final_pending_head_ptr].id),
        .rd_i        (final_pending_q[final_pending_head_ptr].rd),
        .result_id_o (final_result_id),
        .result_rd_o (final_result_rd),
        .rs1_i       (final_pending_q[final_pending_head_ptr].rs1),
        .rs2_i       (final_pending_q[final_pending_head_ptr].rs2),
        .p1_i        (mailbox_p1_q),
        .p2_i        (mailbox_p2_q),
        .result_data (final_result_data)
    );

    //--------------------------------------------------------------------------
    // MX_FUNCT3_DUALREAD_TEST slot: validation-only, not part of the real
    // MXDOTP ISA (see mxdotp_pkg.sv). Kept at its own pre-existing timing
    // (LATENCY_CYCLES-shaped, same as this project's original single-engine
    // design) - this milestone is about DOTP/FINAL/FUSED throughput, not
    // about this instruction's own speed, so its internal timing is
    // deliberately left unchanged. Small enough (pure bit-selection, no real
    // arithmetic) that it's kept inline here rather than as a separate
    // engine module.
    //--------------------------------------------------------------------------

    localparam int DR_LATENCY_CYCLES = 2;  // matches this project's original LATENCY_CYCLES
    localparam int DR_CNT_WIDTH = $clog2(DR_LATENCY_CYCLES + 1);

    logic [DR_CNT_WIDTH-1:0] dr_cycle_cnt_q;
    logic                    dr_busy_q;
    logic                    dr_engine_start, dr_engine_done;
    logic [31:0]             dr_rs1_hi;
    logic [X_RFW_WIDTH-1:0]  dr_result_data_q;

    // Upper 32 bits of the (possibly dual-read) dr_saved_rs1 container -
    // only meaningful when X_RFR_WIDTH >= 64 (this project always
    // instantiates with 64 - see mxdotp_core_top.sv - but guard rather than
    // assume, same as the original mxdotp_execute.sv did).
    generate
        if (X_RFR_WIDTH >= 64) begin : gen_dr_rs1_hi
            assign dr_rs1_hi = dr_saved_rs1[63:32];
        end else begin : gen_no_dr_rs1_hi
            assign dr_rs1_hi = '0;
        end
    endgenerate

    assign dr_engine_start = (dr_state_q == MX_WAIT_COMMIT) &&
                              commit_if.commit_valid &&
                              (commit_if.commit.id == dr_saved_id) &&
                              !commit_if.commit.commit_kill;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dr_busy_q      <= 1'b0;
            dr_cycle_cnt_q <= '0;
        end else if (dr_engine_start && !dr_busy_q) begin
            dr_busy_q      <= 1'b1;
            dr_cycle_cnt_q <= DR_CNT_WIDTH'(DR_LATENCY_CYCLES - 1);
        end else if (dr_busy_q) begin
            if (dr_cycle_cnt_q == '0)
                dr_busy_q <= 1'b0;
            else
                dr_cycle_cnt_q <= dr_cycle_cnt_q - 1'b1;
        end
    end

    assign dr_engine_done = dr_busy_q && (dr_cycle_cnt_q == '0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dr_result_data_q <= '0;
        end else if (dr_engine_done) begin
            dr_result_data_q <= X_RFW_WIDTH'(dr_rs1_hi);
        end
    end

    always_comb begin
        dr_state_d = dr_state_q;
        unique case (dr_state_q)
            MX_IDLE: begin
                if (accept_dr) dr_state_d = MX_WAIT_COMMIT;
            end
            MX_WAIT_COMMIT: begin
                if (commit_if.commit_valid && (commit_if.commit.id == dr_saved_id)) begin
                    dr_state_d = commit_if.commit.commit_kill ? MX_IDLE : MX_COMPUTE;
                end
            end
            MX_COMPUTE: begin
                if (dr_engine_done) dr_state_d = MX_RESULT;
            end
            MX_RESULT: begin
                if ((order_head_tag == MX_SLOT_DUALREAD) && result_if.result_valid && result_if.result_ready)
                    dr_state_d = MX_IDLE;
            end
            default: dr_state_d = MX_IDLE;
        endcase
    end

    //--------------------------------------------------------------------------
    // FUSED slot: the shared pending-commit queue (above) feeds TWO engines -
    // mxdotp_fused_engine.sv (MXFP4) and mxdotp_fp8_fused_engine.sv (MXFP8) -
    // routed by the head entry's element format. No per-slot mxdotp_state_t FSM
    // (see file header). The matching engine's start fires the instant the
    // queue's head is resolved OK (this cycle or latched from an earlier one)
    // AND that engine has room; fused_pending_pop (defined above) advances the
    // queue in lockstep with whichever engine took the head, plus the kill
    // case, which pops unconditionally without touching either engine. The two
    // engines occupy three distinct order-queue slots (MX_SLOT_FUSED /
    // _FUSED8 / _FUSED_M2), so results from the three interleave back into
    // program order correctly.
    //--------------------------------------------------------------------------

    logic fused4_engine_start, fused4_engine_ready;
    logic fused4_result_valid, fused4_result_ready;
    logic [X_ID_WIDTH-1:0]  fused4_result_id;
    logic [4:0]             fused4_result_rd;
    logic [X_RFW_WIDTH-1:0] fused4_result_data;

    logic fused8_engine_start, fused8_engine_ready;
    logic fused8_result_valid, fused8_result_ready;
    logic [X_ID_WIDTH-1:0]  fused8_result_id;
    logic [4:0]             fused8_result_rd;
    logic [X_RFW_WIDTH-1:0] fused8_result_data;

    logic fusedm2_engine_start, fusedm2_engine_ready;
    logic fusedm2_result_valid, fusedm2_result_ready;
    logic [X_ID_WIDTH-1:0]  fusedm2_result_id;
    logic [4:0]             fusedm2_result_rd;
    logic [X_RFW_WIDTH-1:0] fusedm2_result_data;

    // Only the engine whose element format matches the pending-queue head is
    // started this cycle; the other ignores its (deasserted) start_i. The
    // shared pending queue pops when EITHER engine takes the head (or on kill -
    // see fused_pending_pop above). Head-of-line: if the head is MXFP8 but the
    // fp8 engine isn't ready, the head waits rather than letting a younger
    // MXFP4 instruction behind it jump ahead - this preserves strict
    // program-order handoff, so each engine's own result stream stays in
    // program order within its own order-queue slot.
    assign fused4_engine_start  = fused_pending_head_ok && !head_is_fp8 && !head_is_m2 && fused4_engine_ready;
    assign fused8_engine_start  = fused_pending_head_ok &&  head_is_fp8 && fused8_engine_ready;
    assign fusedm2_engine_start = fused_pending_head_ok &&  head_is_m2  && fusedm2_engine_ready;

    // MXFP4 fused engine (plain E2M1 fast path).
    mxdotp_fused_engine #(
        .X_ID_WIDTH  (X_ID_WIDTH),
        .X_RFR_WIDTH (X_RFR_WIDTH),
        .X_RFW_WIDTH (X_RFW_WIDTH)
    ) fused_engine_i (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .start_i        (fused4_engine_start),
        .ready_o        (fused4_engine_ready),
        .id_i           (fused_pending_q[fused_pending_head_ptr].id),
        .rd_i           (fused_pending_q[fused_pending_head_ptr].rd),
        .rs1_i          (fused_pending_q[fused_pending_head_ptr].rs1),
        .rs2_i          (fused_pending_q[fused_pending_head_ptr].rs2),
        .rs3_i          (fused_pending_q[fused_pending_head_ptr].rs3),
        .mx_format_i    (fused_pending_q[fused_pending_head_ptr].format),
        .result_valid_o (fused4_result_valid),
        .result_ready_i (fused4_result_ready),
        .result_id_o    (fused4_result_id),
        .result_rd_o    (fused4_result_rd),
        .result_data_o  (fused4_result_data)
    );

    // MXFP8 fused engine (E4M3/E5M2, sub-format selected by rs3[48]). A
    // deliberately separate engine - see mxdotp_fp8_fused_engine.sv's header
    // for why its front-end/BACK1 differ (per-element exponent placement /
    // early accumulation, not MXFP4's integer sum-then-place).
    mxdotp_fp8_fused_engine #(
        .X_ID_WIDTH  (X_ID_WIDTH),
        .X_RFR_WIDTH (X_RFR_WIDTH),
        .X_RFW_WIDTH (X_RFW_WIDTH)
    ) fused8_engine_i (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .start_i        (fused8_engine_start),
        .ready_o        (fused8_engine_ready),
        .id_i           (fused_pending_q[fused_pending_head_ptr].id),
        .rd_i           (fused_pending_q[fused_pending_head_ptr].rd),
        .rs1_i          (fused_pending_q[fused_pending_head_ptr].rs1),
        .rs2_i          (fused_pending_q[fused_pending_head_ptr].rs2),
        .rs3_i          (fused_pending_q[fused_pending_head_ptr].rs3),
        .mx_format_i    (fused_pending_q[fused_pending_head_ptr].format),
        .result_valid_o (fused8_result_valid),
        .result_ready_i (fused8_result_ready),
        .result_id_o    (fused8_result_id),
        .result_rd_o    (fused8_result_rd),
        .result_data_o  (fused8_result_data)
    );

    // M2XFP4 fused engine (metadata-augmented E2M1; Elem-EM on rs1, Sg-EM on
    // rs2 - the one format where operand ORDER carries meaning, see
    // mxdotp_pkg.sv's ISA NOTE). A deliberately separate engine: its FRONT
    // is a two-subtree reduction with per-subgroup Sg-EM shift-add and top-1
    // re-derivation, and its 43-bit frame (anchor 6) differs from MXFP4's
    // 38-bit one - see mxdotp_m2xfp4_fused_engine.sv's header.
    mxdotp_m2xfp4_fused_engine #(
        .X_ID_WIDTH  (X_ID_WIDTH),
        .X_RFR_WIDTH (X_RFR_WIDTH),
        .X_RFW_WIDTH (X_RFW_WIDTH)
    ) fusedm2_engine_i (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .start_i        (fusedm2_engine_start),
        .ready_o        (fusedm2_engine_ready),
        .id_i           (fused_pending_q[fused_pending_head_ptr].id),
        .rd_i           (fused_pending_q[fused_pending_head_ptr].rd),
        .rs1_i          (fused_pending_q[fused_pending_head_ptr].rs1),
        .rs2_i          (fused_pending_q[fused_pending_head_ptr].rs2),
        .rs3_i          (fused_pending_q[fused_pending_head_ptr].rs3),
        .mx_format_i    (fused_pending_q[fused_pending_head_ptr].format),
        .result_valid_o (fusedm2_result_valid),
        .result_ready_i (fusedm2_result_ready),
        .result_id_o    (fusedm2_result_id),
        .result_rd_o    (fusedm2_result_rd),
        .result_data_o  (fusedm2_result_data)
    );

    // Each engine presents its result only when its OWN slot is at the order
    // queue head. Each engine delivers its own results in program order; the
    // order queue interleaves the two engines' (and the other slots') streams
    // back into global program order. Same gating rationale as the single-
    // engine design, just one instance of it per engine/slot - the engines
    // have no visibility into the shared order queue, so this must live here.
    assign final_result_ready = (order_head_tag == MX_SLOT_FINAL) && result_if.result_ready;
    assign dotp_result_ready_xif = (order_head_tag == MX_SLOT_DOTP) && result_if.result_ready;
    assign fused4_result_ready  = (order_head_tag == MX_SLOT_FUSED)    && result_if.result_ready;
    assign fused8_result_ready  = (order_head_tag == MX_SLOT_FUSED8)   && result_if.result_ready;
    assign fusedm2_result_ready = (order_head_tag == MX_SLOT_FUSED_M2) && result_if.result_ready;

    //--------------------------------------------------------------------------
    // In-order result delivery queue
    //--------------------------------------------------------------------------
    //
    // Tags which slot produced each outstanding instruction, in the order
    // they were accepted. Only the head entry's slot may present
    // result_valid, so results reach the core in acceptance order even
    // though slots can finish computing in any order.
    //
    // Depth is no longer a flat MX_NUM_SLOTS: DOTP/FINAL/DUALREAD_TEST are
    // still at most one outstanding each (unchanged), but FUSED can now
    // have MX_FUSED_MAX_OUTSTANDING simultaneously (see mxdotp_pkg.sv's
    // MX_ORDER_DEPTH derivation) - pointer/count widths are sized generically
    // from MX_ORDER_DEPTH via $clog2 rather than hardcoded, since that depth
    // is no longer a small fixed constant.
    //--------------------------------------------------------------------------

    localparam int MX_ORDER_PTR_WIDTH   = (MX_ORDER_DEPTH <= 1) ? 1 : $clog2(MX_ORDER_DEPTH);
    localparam int MX_ORDER_CNT_WIDTH   = $clog2(MX_ORDER_DEPTH + 1);

    mx_slot_e order_q [0:MX_ORDER_DEPTH-1];
    logic [MX_ORDER_PTR_WIDTH-1:0] order_head_ptr, order_tail_ptr;
    logic [MX_ORDER_CNT_WIDTH-1:0] order_count;

    wire mx_slot_e order_head_tag = order_q[order_head_ptr];
    wire           order_empty    = (order_count == '0);

    logic push_any;
    assign push_any = accept_dotp || accept_final || accept_dr || accept_fused;  // mutually exclusive

    logic pop_any;
    assign pop_any = result_if.result_valid && result_if.result_ready;

    integer oq_i;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            order_head_ptr <= '0;
            order_tail_ptr <= '0;
            order_count    <= '0;
            for (oq_i = 0; oq_i < MX_ORDER_DEPTH; oq_i++) order_q[oq_i] <= MX_SLOT_DOTP;
        end else begin
            if (push_any) begin
                order_q[order_tail_ptr] <= accept_dotp  ? MX_SLOT_DOTP  :
                                            accept_final ? MX_SLOT_FINAL :
                                            accept_dr    ? MX_SLOT_DUALREAD :
                                            (accept_fused && (mx_format == MX_FMT_MXFP8))  ? MX_SLOT_FUSED8   :
                                            (accept_fused && (mx_format == MX_FMT_M2XFP4)) ? MX_SLOT_FUSED_M2 :
                                                            MX_SLOT_FUSED;
                order_tail_ptr <= (order_tail_ptr == MX_ORDER_DEPTH-1) ? '0 : order_tail_ptr + 1'b1;
            end
            if (pop_any) begin
                order_head_ptr <= (order_head_ptr == MX_ORDER_DEPTH-1) ? '0 : order_head_ptr + 1'b1;
            end
            unique case ({push_any, pop_any})
                2'b10:   order_count <= order_count + 1'b1;
                2'b01:   order_count <= order_count - 1'b1;
                default: order_count <= order_count;  // 00 (no change) or 11 (push and pop net to no change)
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Result Interface: driven by whichever slot is at the head of the
    // order queue, and only once that specific slot actually has a result
    // ready - DOTP/FINAL/DUALREAD_TEST via their own MX_RESULT state
    // (unchanged), FUSED via the engine's own result_valid_o directly
    // (no per-slot state left to check - see FUSED slot section above).
    //--------------------------------------------------------------------------

    always_comb begin
        result_if.result_valid = 1'b0;
        result_if.result       = '0;

        if (!order_empty) begin
            unique case (order_head_tag)
                MX_SLOT_DOTP: begin
                    // Gated by !mailbox_full so the XIF handshake can only
                    // complete on the same edge as the mailbox push (see
                    // dotp_result_fire). Never retracted once raised: only a
                    // DOTP push can fill the mailbox, and that is this result.
                    if (dotp_result_valid && !mailbox_full) begin
                        result_if.result_valid = 1'b1;
                        result_if.result.id    = dotp_result_id;
                        result_if.result.rd    = 5'd0;
                        result_if.result.we    = 1'b0;
                        result_if.result.data  = '0;
                    end
                end
                MX_SLOT_FINAL: begin
                    if (final_result_valid) begin
                        result_if.result_valid = 1'b1;
                        result_if.result.id    = final_result_id;
                        result_if.result.rd    = final_result_rd;
                        result_if.result.we    = 1'b1;
                        result_if.result.data  = final_result_data;
                    end
                end
                MX_SLOT_DUALREAD: begin
                    if (dr_state_q == MX_RESULT) begin
                        result_if.result_valid = 1'b1;
                        result_if.result.id    = dr_saved_id;
                        result_if.result.rd    = dr_saved_rd;
                        result_if.result.we    = 1'b1;
                        result_if.result.data  = dr_result_data_q;
                    end
                end
                MX_SLOT_FUSED: begin
                    if (fused4_result_valid) begin
                        result_if.result_valid = 1'b1;
                        result_if.result.id    = fused4_result_id;
                        result_if.result.rd    = fused4_result_rd;
                        result_if.result.we    = 1'b1;
                        result_if.result.data  = fused4_result_data;
                    end
                end
                MX_SLOT_FUSED8: begin
                    if (fused8_result_valid) begin
                        result_if.result_valid = 1'b1;
                        result_if.result.id    = fused8_result_id;
                        result_if.result.rd    = fused8_result_rd;
                        result_if.result.we    = 1'b1;
                        result_if.result.data  = fused8_result_data;
                    end
                end
                MX_SLOT_FUSED_M2: begin
                    if (fusedm2_result_valid) begin
                        result_if.result_valid = 1'b1;
                        result_if.result.id    = fusedm2_result_id;
                        result_if.result.rd    = fusedm2_result_rd;
                        result_if.result.we    = 1'b1;
                        result_if.result.data  = fusedm2_result_data;
                    end
                end
                default: ;  // result_valid stays 0
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Memory Interface (Unused)
    //--------------------------------------------------------------------------

    assign mem_if.mem_valid = 1'b0;
    assign mem_if.mem_req   = '0;

endmodule
