defmodule Hw.PS7 do
  @moduledoc """
  Zynq-7000 Processing System hard macro (`PS7`).

  Wraps the PS7 primitive and surfaces the handful of ports a PL design
  actually needs: the fabric clocks, the fabric resets, and the `M_AXI_GP0`
  master port that the ARM uses to reach registers in the fabric.

  ## Every Zynq design must instantiate this

  Not only designs that talk to the PS. A bitstream with no PS7 instance
  **locks up the processor during PCAP programming** when loaded at runtime
  through `fpga_manager` — which is how we load bitstreams on this board.
  Upstream's own `artyz7-20` example is a pure LED blinky with zero PS
  connections and still carries `(* keep *) PS7 ps7_i();` for exactly this
  reason. The `keep` attribute below stops synthesis pruning it when nothing
  is connected.

  ## What is NOT configured here

  The bitstream does not configure the PS. Clock frequencies (including the
  `FCLK_CLK*` this module emits), DDR timing, MIO muxing and which AXI ports
  are enabled all come from `ps7_init`, run by the FSBL/SPL before Linux
  starts. So:

  - `fclk_clk0`'s actual frequency is whatever `ps7_init` programmed, not
    anything declared here.
  - **FCLKs are off at power-on**, and Linux disables unused ones. A correct
    bitstream can look completely dead until the PS enables its clock. Check
    that before debugging fabric logic.

  ## Clocking

  `FCLKCLK[0]` must go through a `BUFG` before being used as a fabric clock —
  see `Hw.Xilinx.BUFG`. Driving logic directly from the raw PS7 output will
  either fail to route or produce a design with no usable clock tree.

  `fclk_reset0_n` is active-LOW, matching AXI convention, and is **not**
  synchronous to `fclk_clk0`. Synchronise it before using it as a reset in the
  fabric clock domain.

  ## M_AXI_GP0 is AXI3, not AXI4-Lite

  The PS drives a full AXI3 master: transaction IDs, 4-bit `LEN` bursts,
  `LOCK`/`CACHE`/`QOS`. `Hw.AXI4Lite.Slave` speaks AXI4-Lite. The gap that
  matters in practice is small but not empty:

  - IDs must be echoed back — `ARID` to `RID`, `AWID` to `BID` — or the PS
    will not match the response to its request.
  - `RLAST` must be asserted on the final read beat.
  - `ARLEN`/`AWLEN` are exposed here so a design can at least *detect* a burst
    it cannot service. A single-beat access (what `readl`/`writel` and
    `/dev/mem` word accesses generate) has `LEN = 0`.

  Bridging that is the consuming design's job, not this module's.
  """

  use Hw.Component

  # --- Fabric clocks and resets ---------------------------------------------
  output :fclk_clk0, 1
  output :fclk_clk1, 1
  output :fclk_reset0_n, 1

  # --- M_AXI_GP0 clock ------------------------------------------------------
  input :maxigp0_aclk, 1

  # --- M_AXI_GP0 write address channel (PS drives) --------------------------
  output :maxigp0_awid, 12
  output :maxigp0_awaddr, 32
  output :maxigp0_awlen, 4
  output :maxigp0_awsize, 3
  output :maxigp0_awburst, 2
  output :maxigp0_awprot, 3
  output :maxigp0_awvalid, 1
  input :maxigp0_awready, 1

  # --- M_AXI_GP0 write data channel -----------------------------------------
  output :maxigp0_wid, 12
  output :maxigp0_wdata, 32
  output :maxigp0_wstrb, 4
  output :maxigp0_wlast, 1
  output :maxigp0_wvalid, 1
  input :maxigp0_wready, 1

  # --- M_AXI_GP0 write response channel -------------------------------------
  input :maxigp0_bid, 12
  input :maxigp0_bresp, 2
  input :maxigp0_bvalid, 1
  output :maxigp0_bready, 1

  # --- M_AXI_GP0 read address channel ---------------------------------------
  output :maxigp0_arid, 12
  output :maxigp0_araddr, 32
  output :maxigp0_arlen, 4
  output :maxigp0_arsize, 3
  output :maxigp0_arburst, 2
  output :maxigp0_arprot, 3
  output :maxigp0_arvalid, 1
  input :maxigp0_arready, 1

  # --- M_AXI_GP0 read data channel ------------------------------------------
  input :maxigp0_rid, 12
  input :maxigp0_rdata, 32
  input :maxigp0_rresp, 2
  input :maxigp0_rlast, 1
  input :maxigp0_rvalid, 1
  output :maxigp0_rready, 1

  # FCLKCLK / FCLKRESETN are 4-bit buses on the primitive. Bit 0 is the fabric
  # clock. Bit 1 is surfaced because the PS is the only working source of a
  # 200 MHz IDELAYCTRL reference on this board -- every PL CMT failed to lock
  # under openXC7. Read from SLCR on the LibreSDR: IO PLL 999.9 MHz, FCLK1
  # divisors 5 and 1, so FCLK1 is ALREADY 200 MHz with no SLCR write needed.
  wire :fclk_clk_bus, 4
  wire :fclk_resetn_bus, 4

  comb do
    fclk_clk0 = fclk_clk_bus[0..0]
    fclk_clk1 = fclk_clk_bus[1..1]
    fclk_reset0_n = fclk_resetn_bus[0..0]
  end

  # keep="true": a PS7 with nothing connected must still survive synthesis,
  # or runtime PCAP programming hangs the PS.
  blackbox :ps7, "PS7",
    attrs: [keep: "true"],
    ports: [
      FCLKCLK: :fclk_clk_bus,
      FCLKRESETN: :fclk_resetn_bus,
      MAXIGP0ACLK: :maxigp0_aclk,
      MAXIGP0AWID: :maxigp0_awid,
      MAXIGP0AWADDR: :maxigp0_awaddr,
      MAXIGP0AWLEN: :maxigp0_awlen,
      MAXIGP0AWSIZE: :maxigp0_awsize,
      MAXIGP0AWBURST: :maxigp0_awburst,
      MAXIGP0AWPROT: :maxigp0_awprot,
      MAXIGP0AWVALID: :maxigp0_awvalid,
      MAXIGP0AWREADY: :maxigp0_awready,
      MAXIGP0WID: :maxigp0_wid,
      MAXIGP0WDATA: :maxigp0_wdata,
      MAXIGP0WSTRB: :maxigp0_wstrb,
      MAXIGP0WLAST: :maxigp0_wlast,
      MAXIGP0WVALID: :maxigp0_wvalid,
      MAXIGP0WREADY: :maxigp0_wready,
      MAXIGP0BID: :maxigp0_bid,
      MAXIGP0BRESP: :maxigp0_bresp,
      MAXIGP0BVALID: :maxigp0_bvalid,
      MAXIGP0BREADY: :maxigp0_bready,
      MAXIGP0ARID: :maxigp0_arid,
      MAXIGP0ARADDR: :maxigp0_araddr,
      MAXIGP0ARLEN: :maxigp0_arlen,
      MAXIGP0ARSIZE: :maxigp0_arsize,
      MAXIGP0ARBURST: :maxigp0_arburst,
      MAXIGP0ARPROT: :maxigp0_arprot,
      MAXIGP0ARVALID: :maxigp0_arvalid,
      MAXIGP0ARREADY: :maxigp0_arready,
      MAXIGP0RID: :maxigp0_rid,
      MAXIGP0RDATA: :maxigp0_rdata,
      MAXIGP0RRESP: :maxigp0_rresp,
      MAXIGP0RLAST: :maxigp0_rlast,
      MAXIGP0RVALID: :maxigp0_rvalid,
      MAXIGP0RREADY: :maxigp0_rready
    ]
end
