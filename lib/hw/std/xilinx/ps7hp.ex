defmodule Hw.PS7HP do
  @moduledoc """
  Zynq-7000 PS7 with the high-bandwidth PL-to-PS paths: `S_AXI_HP0` (write
  side) and the EMIO GPIO banks, alongside everything `Hw.PS7` already
  exposes (fabric clocks/resets and `M_AXI_GP0`).

  A separate component rather than new ports on `Hw.PS7`, deliberately:
  `Hw.PS7` is instantiated by every live libresdr design, and a new input
  port on a component is a new undriven wire in every existing instance.
  Undriven VALIDs into the PS are exactly the kind of silent hazard this
  project keeps paying for. Nothing changes for `Hw.PS7` users; a design
  opts into this one. One PS7 per design — they wrap the same hard macro.

  ## Why these two paths, together

  On the current LibreSDR firmware the fabric's GP0 AXI slave path is dead
  (unexplained, firmware-level — nervezynq/HANDOFF.md). This component is
  the architecture that does not care:

  - **Data plane**: the PL *masters* sample data into DDR through
    `S_AXI_HP0` (see `Hw.AXIHPWriter`). The lethal GP failure mode — a
    PS-initiated read into the PL that never answers, hanging the CPU with
    no recovery — cannot occur when the PL is the master; a broken PL
    master starves, it cannot wedge the ARM.
  - **Control plane**: EMIO GPIO. The GPIO controller at `0xE000A000` is a
    PS peripheral like SLCR and devcfg — both proven live on this board —
    and its banks 2/3 are 64 wires straight into the fabric with no AXI
    interconnect in the PL at all. Control bits ride `emio_gpio_o`; status
    (write pointer bits, burst/overrun counters, LOCKED, heartbeats) rides
    `emio_gpio_i`.

  ## What the PS must have configured (ps7_init / FSBL territory, NOT the bitstream)

  Same class of trap as `FCLK_CLK0`: a correct bitstream looks dead if the
  PS side is not set up. For HP0, from Linux, *read before writing*:

  - `SLCR.LVL_SHFTR_EN` (0xF8000900) = 0xF — already required for GP, listed
    for completeness.
  - FCLK running (0xF8000170 / 0x180) and this component's `saxihp0_aclk`
    driven from the same BUFG'd fabric clock the writer runs on.
  - AFI0 block (0xF800_8000) — HP0's width/QoS knobs. The 64-bit width is
    the reset default on 7-series but Vivado's ps7_init normally writes it;
    this flow has no ps7_init for HP, so the first bring-up session should
    dump the AFI0 registers and record what the shipped FSBL left there
    before trusting UG585's reset values. (Deliberately not hardcoding
    offsets here that have not been read off this board — UG585 ch. 5 &
    appendix B.)
  - EMIO GPIO banks 2/3: `MIO_MST_TRI0/1` do not apply; the EMIO direction
    registers (`XGPIOPS` bank 2/3 DIRM/OEN at 0xE000A284.. and 0xE000A2C4..)
    must be set from Linux for output bits; inputs need nothing.

  ## Unbound-port rules for instantiators

  - `emio_gpio_i`: drive it (zero-extend unused bits). Leaving a component
    input unbound leaves the blackbox input on an undriven net.
  - The HP0 *read* channel is not exposed at all — its blackbox ports are
    simply not listed, so nextpnr ties `SAXIHP0ARVALID` and friends to
    constants. It gets added when `Hw.AXIHPReader` (TX direction) exists,
    not before.
  - `SAXIHP0RDISSUECAP1EN` / `WRISSUECAP1EN` are likewise unlisted (tied by
    nextpnr): issuance capping is a QoS feature this design does not use.

  ## Observability

  `saxihp0_wacount` (pending write addresses) and `saxihp0_wcount` (write
  data FIFO occupancy) come straight out of the PS7 macro. During bring-up,
  `wacount`/`wcount` vs the writer's `bursts` counter distinguishes "the PL
  never issued" from "the PS accepted and absorbed" from "stuck mid-burst"
  — the same triage the devcfg DMA queue flags gave the readback work.
  """

  use Hw.Component

  # --- Fabric clocks and resets ----------------------------------------------
  output :fclk_clk0, 1
  output :fclk_clk1, 1
  output :fclk_reset0_n, 1

  # --- M_AXI_GP0 (identical surface to Hw.PS7) --------------------------------
  input :maxigp0_aclk, 1

  output :maxigp0_awid, 12
  output :maxigp0_awaddr, 32
  output :maxigp0_awlen, 4
  output :maxigp0_awsize, 3
  output :maxigp0_awburst, 2
  output :maxigp0_awprot, 3
  output :maxigp0_awvalid, 1
  input :maxigp0_awready, 1

  output :maxigp0_wid, 12
  output :maxigp0_wdata, 32
  output :maxigp0_wstrb, 4
  output :maxigp0_wlast, 1
  output :maxigp0_wvalid, 1
  input :maxigp0_wready, 1

  input :maxigp0_bid, 12
  input :maxigp0_bresp, 2
  input :maxigp0_bvalid, 1
  output :maxigp0_bready, 1

  output :maxigp0_arid, 12
  output :maxigp0_araddr, 32
  output :maxigp0_arlen, 4
  output :maxigp0_arsize, 3
  output :maxigp0_arburst, 2
  output :maxigp0_arprot, 3
  output :maxigp0_arvalid, 1
  input :maxigp0_arready, 1

  input :maxigp0_rid, 12
  input :maxigp0_rdata, 32
  input :maxigp0_rresp, 2
  input :maxigp0_rlast, 1
  input :maxigp0_rvalid, 1
  output :maxigp0_rready, 1

  # --- S_AXI_HP0, write side only (PL is the master) ---------------------------
  # Widths are the PS7 primitive's own (yosys cells_xtra.v): ID 6, LEN 4
  # (AXI3), SIZE 2, WDATA 64, WSTRB 8. A 2-bit AWSIZE carrying 3 means
  # AxSIZE 0b011 = 8 bytes/beat.
  input :saxihp0_aclk, 1

  input :saxihp0_awid, 6
  input :saxihp0_awaddr, 32
  input :saxihp0_awlen, 4
  input :saxihp0_awsize, 2
  input :saxihp0_awburst, 2
  input :saxihp0_awlock, 2
  input :saxihp0_awcache, 4
  input :saxihp0_awprot, 3
  input :saxihp0_awqos, 4
  input :saxihp0_awvalid, 1
  output :saxihp0_awready, 1

  input :saxihp0_wid, 6
  input :saxihp0_wdata, 64
  input :saxihp0_wstrb, 8
  input :saxihp0_wlast, 1
  input :saxihp0_wvalid, 1
  output :saxihp0_wready, 1

  output :saxihp0_bid, 6
  output :saxihp0_bresp, 2
  output :saxihp0_bvalid, 1
  input :saxihp0_bready, 1

  output :saxihp0_aresetn, 1
  output :saxihp0_wacount, 6
  output :saxihp0_wcount, 8

  # --- EMIO GPIO banks 2/3 — the AXI-free control plane -------------------------
  input :emio_gpio_i, 64
  output :emio_gpio_o, 64
  output :emio_gpio_tn, 64

  wire :fclk_clk_bus, 4
  wire :fclk_resetn_bus, 4

  comb do
    fclk_clk0 = fclk_clk_bus[0..0]
    fclk_clk1 = fclk_clk_bus[1..1]
    fclk_reset0_n = fclk_resetn_bus[0..0]
  end

  # keep="true": a PS7 with nothing connected must still survive synthesis,
  # or runtime PCAP programming hangs the PS. (Same rule as Hw.PS7.)
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
      MAXIGP0RREADY: :maxigp0_rready,
      SAXIHP0ACLK: :saxihp0_aclk,
      SAXIHP0AWID: :saxihp0_awid,
      SAXIHP0AWADDR: :saxihp0_awaddr,
      SAXIHP0AWLEN: :saxihp0_awlen,
      SAXIHP0AWSIZE: :saxihp0_awsize,
      SAXIHP0AWBURST: :saxihp0_awburst,
      SAXIHP0AWLOCK: :saxihp0_awlock,
      SAXIHP0AWCACHE: :saxihp0_awcache,
      SAXIHP0AWPROT: :saxihp0_awprot,
      SAXIHP0AWQOS: :saxihp0_awqos,
      SAXIHP0AWVALID: :saxihp0_awvalid,
      SAXIHP0AWREADY: :saxihp0_awready,
      SAXIHP0WID: :saxihp0_wid,
      SAXIHP0WDATA: :saxihp0_wdata,
      SAXIHP0WSTRB: :saxihp0_wstrb,
      SAXIHP0WLAST: :saxihp0_wlast,
      SAXIHP0WVALID: :saxihp0_wvalid,
      SAXIHP0WREADY: :saxihp0_wready,
      SAXIHP0BID: :saxihp0_bid,
      SAXIHP0BRESP: :saxihp0_bresp,
      SAXIHP0BVALID: :saxihp0_bvalid,
      SAXIHP0BREADY: :saxihp0_bready,
      SAXIHP0ARESETN: :saxihp0_aresetn,
      SAXIHP0WACOUNT: :saxihp0_wacount,
      SAXIHP0WCOUNT: :saxihp0_wcount,
      EMIOGPIOI: :emio_gpio_i,
      EMIOGPIOO: :emio_gpio_o,
      EMIOGPIOTN: :emio_gpio_tn
    ]
end
