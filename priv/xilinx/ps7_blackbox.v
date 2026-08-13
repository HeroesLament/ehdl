// PS7 blackbox declaration for yosys.
//
// nextpnr-xilinx ships no PS7 stub, and yosys's cells_sim.v does not define it
// either. Upstream's own artyz7-20 example gets away with that because it
// instantiates `PS7 ps7_i();` with nothing connected — yosys never has to know
// which way any port faces.
//
// A design that actually talks to the PS does need it. Without a declaration
// yosys treats PS7 as an unknown module with unknown port directions, cannot
// see that MAXIGP0* outputs *drive* fabric logic, concludes that logic is dead
// and removes it. The failure is silent and spectacular: synthesis succeeds,
// reports "2 cells" — one BUFG, one PS7 — and every register you wrote is
// gone.
//
// Only the ports used by Hw.PS7 are declared. Undeclared ports on a blackbox
// are fine; nextpnr-xilinx ties unused PS7 inputs to constants during
// placement. Widths and directions are per UG585, viewed from the PL: a port
// the PS drives is an `output` here.

(* blackbox *)
module PS7 (
    // Fabric clocks and resets
    output [3:0]  FCLKCLK,
    output [3:0]  FCLKRESETN,

    // M_AXI_GP0 clock
    input         MAXIGP0ACLK,

    // M_AXI_GP0 write address channel (PS drives)
    output [11:0] MAXIGP0AWID,
    output [31:0] MAXIGP0AWADDR,
    output [3:0]  MAXIGP0AWLEN,
    output [2:0]  MAXIGP0AWSIZE,
    output [1:0]  MAXIGP0AWBURST,
    output [2:0]  MAXIGP0AWPROT,
    output        MAXIGP0AWVALID,
    input         MAXIGP0AWREADY,

    // M_AXI_GP0 write data channel (PS drives)
    output [11:0] MAXIGP0WID,
    output [31:0] MAXIGP0WDATA,
    output [3:0]  MAXIGP0WSTRB,
    output        MAXIGP0WLAST,
    output        MAXIGP0WVALID,
    input         MAXIGP0WREADY,

    // M_AXI_GP0 write response channel (PL drives back)
    input  [11:0] MAXIGP0BID,
    input  [1:0]  MAXIGP0BRESP,
    input         MAXIGP0BVALID,
    output        MAXIGP0BREADY,

    // M_AXI_GP0 read address channel (PS drives)
    output [11:0] MAXIGP0ARID,
    output [31:0] MAXIGP0ARADDR,
    output [3:0]  MAXIGP0ARLEN,
    output [2:0]  MAXIGP0ARSIZE,
    output [1:0]  MAXIGP0ARBURST,
    output [2:0]  MAXIGP0ARPROT,
    output        MAXIGP0ARVALID,
    input         MAXIGP0ARREADY,

    // M_AXI_GP0 read data channel (PL drives back)
    input  [11:0] MAXIGP0RID,
    input  [31:0] MAXIGP0RDATA,
    input  [1:0]  MAXIGP0RRESP,
    input         MAXIGP0RLAST,
    input         MAXIGP0RVALID,
    output        MAXIGP0RREADY
);
endmodule
