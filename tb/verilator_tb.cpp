//==============================================================================
// File    : verilator_tb.cpp
// Project : MXDOTP XIF Coprocessor - Verilator Testbench
//------------------------------------------------------------------------------
// Description:
//   Minimal C++ driver for Verilator.
//
//   tb_mxdotp_core.sv is declared as `module tb_mxdotp_core;` - it has NO
//   ports. It generates its own clk_i/rst_ni internally, runs its own
//   scoreboard, and its own watchdog calls $finish (pass) or $fatal
//   (fail) when done. This harness therefore does not drive any signal -
//   there is nothing to drive. Its only job is to keep simulation time
//   advancing (required for --timing designs, which rely on Verilator's
//   event scheduler to run the SV always/initial blocks with delays) and
//   stop when the design itself is finished.
//
//   Pass/fail is intentionally NOT inspected here via hierarchical signal
//   access. tb_mxdotp_core.sv's watchdog calls $fatal on failure, which
//   Verilator converts into a non-zero process exit code automatically -
//   so `make`/CI sees failures for free, and this file never goes stale
//   relative to the scoreboard's internal state names.
//
//   Time advances straight to the next scheduled event (Verilator 5 --timing:
//   eventsPending()/nextTimeSlot()) rather than 1 ps per eval(): the design
//   only changes at its own #delays and clock edges, so the stepped-over
//   picoseconds never had anything to evaluate. That was ~10,000 evals per
//   10 ns clock; long program-image runs (make loop) need the speed.
//
//   Plusargs:
//     +notrace   do not write tb_mxdotp_core.vcd (default: write it, as before)
//==============================================================================

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vtb_mxdotp_core.h"

#include <cstdio>

int main(int argc, char** argv) {
    VerilatedContext* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);
    contextp->traceEverOn(true);

    Vtb_mxdotp_core* top = new Vtb_mxdotp_core{contextp};

    const bool trace_on = (contextp->commandArgsPlusMatch("notrace")[0] == '\0');
    VerilatedVcdC* tfp = nullptr;
    if (trace_on) {
        tfp = new VerilatedVcdC;
        top->trace(tfp, 99);
        tfp->open("tb_mxdotp_core.vcd");
    }

    printf("Verilator testbench starting...\n");
    printf("(tb_mxdotp_core.sv drives its own clock/reset and watchdog;\n"
           " this harness just pumps simulation time.)\n");

    while (!contextp->gotFinish()) {
        top->eval();
        if (tfp) tfp->dump(contextp->time());
        if (contextp->gotFinish()) break;   // report the $finish time itself, not the next slot
        if (!top->eventsPending()) break;   // nothing left to run - only reachable if the TB never $finishes
        contextp->time(top->nextTimeSlot());
    }

    printf("\nSimulation finished at time %llu\n",
           static_cast<unsigned long long>(contextp->time()));

    if (tfp) {
        tfp->close();
        delete tfp;
    }

    top->final();
    delete top;
    delete contextp;

    if (trace_on) printf("Waveform written to tb_mxdotp_core.vcd\n");
    return 0;
}