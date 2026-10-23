// ASIC clock gate for nangate45 (synthesis only; simulation uses
// bhv/cv32e40x_sim_clock_gate.sv through the manifest).
//
// CLKGATETST_X1, nangate45's integrated clock-gating cell with test enable
// (NangateOpenCellLibrary_typical.lib, checked 23 Oct 2026): pins CK, E, SE
// (inputs) and GCK (output); clock_gating_integrated_cell
// latch_posedge_precontrol; latch IQ transparent while CK is low and loading
// E | SE, GCK = IQ & CK. That is the behaviour of the simulation model (latch
// en_i | scan_cg_en_i while clk_i is low, clk_o = clk_i & latch). It replaces
// the OPENROAD_CLKGATE wrapper of the OpenROAD flow, which plain nangate45
// libraries do not define.
module cv32e40x_clock_gate
#(
  parameter LIB = 0
)
(
    input  logic clk_i,
    input  logic en_i,
    input  logic scan_cg_en_i,
    output logic clk_o
);

    CLKGATETST_X1 u_clkgate (
        .CK  ( clk_i        ),
        .E   ( en_i         ),
        .SE  ( scan_cg_en_i ),
        .GCK ( clk_o        )
    );

endmodule
