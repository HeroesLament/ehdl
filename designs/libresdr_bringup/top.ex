defmodule LibreSDRBringup.Top do
  @moduledoc """
  LibreSDR (Zynq-7020) PL bring-up: the smallest design that proves the fabric
  is alive and addressable from Linux.

  PS7 → BUFG → AXI4-Lite register file. Nothing else. If the ARM can read the
  magic word out of this, then the bitstream loaded, the FCLK is running, the
  PS-PL level shifters are up, and AXI routes — which is every unknown in the
  Zynq bring-up path, answered by one `readl`.

  ## Poking it from IEx

  The PL is at `0x4000_0000` (Zynq M_AXI_GP0 base).

      0x45484431 = read32(0x4000_0000)   # MAGIC "EHD1" — the link works
      0x00010000 = read32(0x4000_0004)   # VERSION
      write32(0x4000_0008, 0xDEADBEEF)
      0xDEADBEEF = read32(0x4000_0008)   # SCRATCH — writes land and persist
      write32(0x4000_000C, 0xA5)         # CTRL — PS drives the fabric
      read32(0x4000_0010)                # STATUS — fabric drives the PS

  STATUS returns `{ctrl[7:0], heartbeat[23:0]}`. The heartbeat is a free-running
  counter on the AXI clock, so two reads returning *different* values prove the
  fabric clock is actually toggling — distinguishing "FCLK is dead" from "AXI is
  broken", which otherwise look identical from userspace.

  ## One reset, driven to every flop

  Every register in this design is reset by `fclk_reset0_n`, and that
  uniformity is the point.

  A 7-series half-slice shares one control set: all four flops must agree on
  whether the SR pin is used. Mixed usage makes nextpnr-xilinx's packer place
  them together anyway and then fail at FASM emission with "disagrees with its
  half-slice on 'is_srused'". Tying the reset off does NOT avoid this — yosys
  still infers a synchronous reset from the FSM `defaults` pattern (assign 0
  unless a state overrides), so some flops end up SR-used and some do not.
  Giving every flop the same reset is what makes the control set uniform.

  So there is deliberately no reset synchroniser here: its two flops would
  themselves be unreset, reintroducing exactly the mix we are trying to avoid.

  The tradeoff is real and worth stating: `FCLKRESETN` is not synchronous to
  `FCLK`, so its release is not synchronised to this clock domain. For a
  bring-up design whose job is to answer "does AXI work at all", that is
  acceptable. A design carrying sample data should synchronise it — and will
  then need to deal with the control-set question deliberately.

  ## Order of operations

  1. Load the bitstream via `fpga_manager` (`.bin`, byte-swapped)
  2. Confirm `/sys/class/fpga_manager/fpga0/state` reads `operating`
  3. Only then touch `0x4000_0000`

  Reading PL addresses before a bitstream is loaded does not fault — the Zynq
  AXI interconnect has no timeout and the CPU hangs forever. Check the state
  first, every time.

  ## AXI3 → AXI4-Lite bridging

  `M_AXI_GP0` is AXI3: it carries transaction IDs and 4-bit burst lengths.
  `Hw.AXI4Lite.Slave` speaks AXI4-Lite. Three things reconcile them here:

  - `ARID`/`AWID` are captured and echoed on `RID`/`BID`, or the PS cannot
    match a response to its request.
  - `RLAST` is tied high — correct only for single-beat transactions.
  - `ARLEN`/`AWLEN` are *not* honoured. `readl`/`writel` and `/dev/mem` word
    accesses issue `LEN = 0`, which is fine. A `memcpy` across this region
    would issue a burst and hang. Do not do that until there is a real bridge.
  """

  use Hw.Component

  # --- PS7 fabric clock / reset ---------------------------------------------
  wire :fclk_clk0, 1
  wire :fclk_reset0_n, 1
  wire :axi_clk, 1

  clock :axi_clk, freq: 50.0


  # --- PS7 <-> AXI-Lite slave wiring ----------------------------------------
  wire :awid, 12
  wire :awaddr, 32
  wire :awvalid, 1
  wire :awready, 1
  wire :wdata, 32
  wire :wstrb, 4
  wire :wvalid, 1
  wire :wready, 1
  wire :bresp, 2
  wire :bvalid, 1
  wire :bready, 1
  wire :arid, 12
  wire :araddr, 32
  wire :arvalid, 1
  wire :arready, 1
  wire :rdata, 32
  wire :rresp, 2
  wire :rvalid, 1
  wire :rready, 1

  # Captured IDs, echoed back on the response channels.
  wire :bid_q, 12, init: 0
  wire :rid_q, 12, init: 0

  # RLAST, tied high. AXI4-Lite has no RLAST, but M_AXI_GP0 is AXI3 and the PS
  # will not retire a read until it sees it. Leaving it undriven is a silent
  # hang: AR is accepted, RVALID comes back, and the PS waits forever for a
  # final beat that never arrives -- with the bitstream loaded, the clock
  # running, level shifters up and the PL out of reset, so everything else
  # looks perfectly healthy. Correct only because every transaction here is
  # single-beat (ARLEN = 0), which is what readl/writel and /dev/mem generate.
  wire :rlast_tie, 1

  # --- Fabric-facing register file signals ----------------------------------
  wire :ctrl, 32
  wire :status, 32
  wire :heartbeat, 24, init: 0

  instance :ps, Hw.PS7,
    fclk_clk0: :fclk_clk0,
    fclk_reset0_n: :fclk_reset0_n,
    maxigp0_aclk: :axi_clk,
    maxigp0_awid: :awid,
    maxigp0_awaddr: :awaddr,
    maxigp0_awvalid: :awvalid,
    maxigp0_awready: :awready,
    maxigp0_wdata: :wdata,
    maxigp0_wstrb: :wstrb,
    maxigp0_wvalid: :wvalid,
    maxigp0_wready: :wready,
    maxigp0_bresp: :bresp,
    maxigp0_bvalid: :bvalid,
    maxigp0_bready: :bready,
    maxigp0_bid: :bid_q,
    maxigp0_arid: :arid,
    maxigp0_araddr: :araddr,
    maxigp0_arvalid: :arvalid,
    maxigp0_arready: :arready,
    maxigp0_rdata: :rdata,
    maxigp0_rresp: :rresp,
    maxigp0_rvalid: :rvalid,
    maxigp0_rready: :rready,
    maxigp0_rlast: :rlast_tie,
    maxigp0_rid: :rid_q

  instance :clkbuf, Hw.Xilinx.BUFG,
    i: :fclk_clk0,
    o: :axi_clk

  # The slave takes only the low 12 address bits: one 4 KB page is the minimum
  # the PS decodes, and the register map needs 5 words of it.
  instance :axil, Hw.AXI4Lite.Slave,
    aclk: :axi_clk,
    aresetn: :fclk_reset0_n,
    s_axi_awaddr: :awaddr_low,
    s_axi_awvalid: :awvalid,
    s_axi_awready: :awready,
    s_axi_wdata: :wdata,
    s_axi_wstrb: :wstrb,
    s_axi_wvalid: :wvalid,
    s_axi_wready: :wready,
    s_axi_bresp: :bresp,
    s_axi_bvalid: :bvalid,
    s_axi_bready: :bready,
    s_axi_araddr: :araddr_low,
    s_axi_arvalid: :arvalid,
    s_axi_arready: :arready,
    s_axi_rdata: :rdata,
    s_axi_rresp: :rresp,
    s_axi_rvalid: :rvalid,
    s_axi_rready: :rready,
    ctrl0: :ctrl,
    ctrl1: :ctrl_unused1,
    ctrl2: :ctrl_unused2,
    ctrl3: :ctrl_unused3,
    status0: :status,
    status1: :zero32,
    status2: :zero32,
    status3: :zero32

  wire :awaddr_low, 12
  wire :araddr_low, 12

  comb do
    rlast_tie = 1
    zero32 = 0
    awaddr_low = awaddr[11..0]
    araddr_low = araddr[11..0]

    # STATUS = {ctrl[7:0], heartbeat[23:0]}. Two reads returning different
    # values prove the fabric clock is running.
    status = {ctrl[7..0], heartbeat}
  end

  on :axi_clk do
    if fclk_reset0_n == 0 do
      heartbeat = 0
    else
      heartbeat = heartbeat + 1
    end
  end

  # Capture the transaction ID at accept time and hold it for the response.
  on :axi_clk do
    if fclk_reset0_n == 0 do
      bid_q = 0
      rid_q = 0
    else
      if awvalid == 1 and awready == 1 do
        bid_q = awid
      end

      if arvalid == 1 and arready == 1 do
        rid_q = arid
      end
    end
  end
end
