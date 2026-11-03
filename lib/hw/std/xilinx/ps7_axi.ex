defmodule Hw.PS7AXI do
  @moduledoc """
  Zynq-7000 PS7 with every AXI port the PL can reach as a full port list:
  M_AXI_GP0 (the control plane) and the PS slave ports S_AXI_GP0/1,
  S_AXI_HP0-3 and S_AXI_ACP, plus FCLK0 and its reset. Generated from
  prjxray's site_type_PS7.json (names, directions, widths) by the
  fabfarm axi_observatory work; widths are the PS7 primitive's own.

  Every input is bound: a design that does not drive a port must tie it
  (an undriven VALID into the PS is the hazard `Hw.PS7` warns about).
  """

  use Hw.Component

  output :fclk_clk0, 1
  output :fclk_reset0_n, 1

  input :maxigp0aclk, 1
  output :maxigp0araddr, 32
  output :maxigp0arburst, 2
  output :maxigp0arcache, 4
  output :maxigp0aresetn, 1
  output :maxigp0arid, 12
  output :maxigp0arlen, 4
  output :maxigp0arlock, 2
  output :maxigp0arprot, 3
  output :maxigp0arqos, 4
  input :maxigp0arready, 1
  output :maxigp0arsize, 2
  output :maxigp0arvalid, 1
  output :maxigp0awaddr, 32
  output :maxigp0awburst, 2
  output :maxigp0awcache, 4
  output :maxigp0awid, 12
  output :maxigp0awlen, 4
  output :maxigp0awlock, 2
  output :maxigp0awprot, 3
  output :maxigp0awqos, 4
  input :maxigp0awready, 1
  output :maxigp0awsize, 2
  output :maxigp0awvalid, 1
  input :maxigp0bid, 12
  output :maxigp0bready, 1
  input :maxigp0bresp, 2
  input :maxigp0bvalid, 1
  input :maxigp0rdata, 32
  input :maxigp0rid, 12
  input :maxigp0rlast, 1
  output :maxigp0rready, 1
  input :maxigp0rresp, 2
  input :maxigp0rvalid, 1
  output :maxigp0wdata, 32
  output :maxigp0wid, 12
  output :maxigp0wlast, 1
  input :maxigp0wready, 1
  output :maxigp0wstrb, 4
  output :maxigp0wvalid, 1
  input :saxiacpaclk, 1
  input :saxiacparaddr, 32
  input :saxiacparburst, 2
  input :saxiacparcache, 4
  output :saxiacparesetn, 1
  input :saxiacparid, 3
  input :saxiacparlen, 4
  input :saxiacparlock, 2
  input :saxiacparprot, 3
  input :saxiacparqos, 4
  output :saxiacparready, 1
  input :saxiacparsize, 2
  input :saxiacparuser, 5
  input :saxiacparvalid, 1
  input :saxiacpawaddr, 32
  input :saxiacpawburst, 2
  input :saxiacpawcache, 4
  input :saxiacpawid, 3
  input :saxiacpawlen, 4
  input :saxiacpawlock, 2
  input :saxiacpawprot, 3
  input :saxiacpawqos, 4
  output :saxiacpawready, 1
  input :saxiacpawsize, 2
  input :saxiacpawuser, 5
  input :saxiacpawvalid, 1
  output :saxiacpbid, 3
  input :saxiacpbready, 1
  output :saxiacpbresp, 2
  output :saxiacpbvalid, 1
  output :saxiacprdata, 64
  output :saxiacprid, 3
  output :saxiacprlast, 1
  input :saxiacprready, 1
  output :saxiacprresp, 2
  output :saxiacprvalid, 1
  input :saxiacpwdata, 64
  input :saxiacpwid, 3
  input :saxiacpwlast, 1
  output :saxiacpwready, 1
  input :saxiacpwstrb, 8
  input :saxiacpwvalid, 1
  input :saxigp0aclk, 1
  input :saxigp0araddr, 32
  input :saxigp0arburst, 2
  input :saxigp0arcache, 4
  output :saxigp0aresetn, 1
  input :saxigp0arid, 6
  input :saxigp0arlen, 4
  input :saxigp0arlock, 2
  input :saxigp0arprot, 3
  input :saxigp0arqos, 4
  output :saxigp0arready, 1
  input :saxigp0arsize, 2
  input :saxigp0arvalid, 1
  input :saxigp0awaddr, 32
  input :saxigp0awburst, 2
  input :saxigp0awcache, 4
  input :saxigp0awid, 6
  input :saxigp0awlen, 4
  input :saxigp0awlock, 2
  input :saxigp0awprot, 3
  input :saxigp0awqos, 4
  output :saxigp0awready, 1
  input :saxigp0awsize, 2
  input :saxigp0awvalid, 1
  output :saxigp0bid, 6
  input :saxigp0bready, 1
  output :saxigp0bresp, 2
  output :saxigp0bvalid, 1
  output :saxigp0rdata, 32
  output :saxigp0rid, 6
  output :saxigp0rlast, 1
  input :saxigp0rready, 1
  output :saxigp0rresp, 2
  output :saxigp0rvalid, 1
  input :saxigp0wdata, 32
  input :saxigp0wid, 6
  input :saxigp0wlast, 1
  output :saxigp0wready, 1
  input :saxigp0wstrb, 4
  input :saxigp0wvalid, 1
  input :saxigp1aclk, 1
  input :saxigp1araddr, 32
  input :saxigp1arburst, 2
  input :saxigp1arcache, 4
  output :saxigp1aresetn, 1
  input :saxigp1arid, 6
  input :saxigp1arlen, 4
  input :saxigp1arlock, 2
  input :saxigp1arprot, 3
  input :saxigp1arqos, 4
  output :saxigp1arready, 1
  input :saxigp1arsize, 2
  input :saxigp1arvalid, 1
  input :saxigp1awaddr, 32
  input :saxigp1awburst, 2
  input :saxigp1awcache, 4
  input :saxigp1awid, 6
  input :saxigp1awlen, 4
  input :saxigp1awlock, 2
  input :saxigp1awprot, 3
  input :saxigp1awqos, 4
  output :saxigp1awready, 1
  input :saxigp1awsize, 2
  input :saxigp1awvalid, 1
  output :saxigp1bid, 6
  input :saxigp1bready, 1
  output :saxigp1bresp, 2
  output :saxigp1bvalid, 1
  output :saxigp1rdata, 32
  output :saxigp1rid, 6
  output :saxigp1rlast, 1
  input :saxigp1rready, 1
  output :saxigp1rresp, 2
  output :saxigp1rvalid, 1
  input :saxigp1wdata, 32
  input :saxigp1wid, 6
  input :saxigp1wlast, 1
  output :saxigp1wready, 1
  input :saxigp1wstrb, 4
  input :saxigp1wvalid, 1
  input :saxihp0aclk, 1
  input :saxihp0araddr, 32
  input :saxihp0arburst, 2
  input :saxihp0arcache, 4
  output :saxihp0aresetn, 1
  input :saxihp0arid, 6
  input :saxihp0arlen, 4
  input :saxihp0arlock, 2
  input :saxihp0arprot, 3
  input :saxihp0arqos, 4
  output :saxihp0arready, 1
  input :saxihp0arsize, 2
  input :saxihp0arvalid, 1
  input :saxihp0awaddr, 32
  input :saxihp0awburst, 2
  input :saxihp0awcache, 4
  input :saxihp0awid, 6
  input :saxihp0awlen, 4
  input :saxihp0awlock, 2
  input :saxihp0awprot, 3
  input :saxihp0awqos, 4
  output :saxihp0awready, 1
  input :saxihp0awsize, 2
  input :saxihp0awvalid, 1
  output :saxihp0bid, 6
  input :saxihp0bready, 1
  output :saxihp0bresp, 2
  output :saxihp0bvalid, 1
  output :saxihp0racount, 3
  output :saxihp0rcount, 8
  output :saxihp0rdata, 64
  input :saxihp0rdissuecap1en, 1
  output :saxihp0rid, 6
  output :saxihp0rlast, 1
  input :saxihp0rready, 1
  output :saxihp0rresp, 2
  output :saxihp0rvalid, 1
  output :saxihp0wacount, 6
  output :saxihp0wcount, 8
  input :saxihp0wdata, 64
  input :saxihp0wid, 6
  input :saxihp0wlast, 1
  output :saxihp0wready, 1
  input :saxihp0wrissuecap1en, 1
  input :saxihp0wstrb, 8
  input :saxihp0wvalid, 1
  input :saxihp1aclk, 1
  input :saxihp1araddr, 32
  input :saxihp1arburst, 2
  input :saxihp1arcache, 4
  output :saxihp1aresetn, 1
  input :saxihp1arid, 6
  input :saxihp1arlen, 4
  input :saxihp1arlock, 2
  input :saxihp1arprot, 3
  input :saxihp1arqos, 4
  output :saxihp1arready, 1
  input :saxihp1arsize, 2
  input :saxihp1arvalid, 1
  input :saxihp1awaddr, 32
  input :saxihp1awburst, 2
  input :saxihp1awcache, 4
  input :saxihp1awid, 6
  input :saxihp1awlen, 4
  input :saxihp1awlock, 2
  input :saxihp1awprot, 3
  input :saxihp1awqos, 4
  output :saxihp1awready, 1
  input :saxihp1awsize, 2
  input :saxihp1awvalid, 1
  output :saxihp1bid, 6
  input :saxihp1bready, 1
  output :saxihp1bresp, 2
  output :saxihp1bvalid, 1
  output :saxihp1racount, 3
  output :saxihp1rcount, 8
  output :saxihp1rdata, 64
  input :saxihp1rdissuecap1en, 1
  output :saxihp1rid, 6
  output :saxihp1rlast, 1
  input :saxihp1rready, 1
  output :saxihp1rresp, 2
  output :saxihp1rvalid, 1
  output :saxihp1wacount, 6
  output :saxihp1wcount, 8
  input :saxihp1wdata, 64
  input :saxihp1wid, 6
  input :saxihp1wlast, 1
  output :saxihp1wready, 1
  input :saxihp1wrissuecap1en, 1
  input :saxihp1wstrb, 8
  input :saxihp1wvalid, 1
  input :saxihp2aclk, 1
  input :saxihp2araddr, 32
  input :saxihp2arburst, 2
  input :saxihp2arcache, 4
  output :saxihp2aresetn, 1
  input :saxihp2arid, 6
  input :saxihp2arlen, 4
  input :saxihp2arlock, 2
  input :saxihp2arprot, 3
  input :saxihp2arqos, 4
  output :saxihp2arready, 1
  input :saxihp2arsize, 2
  input :saxihp2arvalid, 1
  input :saxihp2awaddr, 32
  input :saxihp2awburst, 2
  input :saxihp2awcache, 4
  input :saxihp2awid, 6
  input :saxihp2awlen, 4
  input :saxihp2awlock, 2
  input :saxihp2awprot, 3
  input :saxihp2awqos, 4
  output :saxihp2awready, 1
  input :saxihp2awsize, 2
  input :saxihp2awvalid, 1
  output :saxihp2bid, 6
  input :saxihp2bready, 1
  output :saxihp2bresp, 2
  output :saxihp2bvalid, 1
  output :saxihp2racount, 3
  output :saxihp2rcount, 8
  output :saxihp2rdata, 64
  input :saxihp2rdissuecap1en, 1
  output :saxihp2rid, 6
  output :saxihp2rlast, 1
  input :saxihp2rready, 1
  output :saxihp2rresp, 2
  output :saxihp2rvalid, 1
  output :saxihp2wacount, 6
  output :saxihp2wcount, 8
  input :saxihp2wdata, 64
  input :saxihp2wid, 6
  input :saxihp2wlast, 1
  output :saxihp2wready, 1
  input :saxihp2wrissuecap1en, 1
  input :saxihp2wstrb, 8
  input :saxihp2wvalid, 1
  input :saxihp3aclk, 1
  input :saxihp3araddr, 32
  input :saxihp3arburst, 2
  input :saxihp3arcache, 4
  output :saxihp3aresetn, 1
  input :saxihp3arid, 6
  input :saxihp3arlen, 4
  input :saxihp3arlock, 2
  input :saxihp3arprot, 3
  input :saxihp3arqos, 4
  output :saxihp3arready, 1
  input :saxihp3arsize, 2
  input :saxihp3arvalid, 1
  input :saxihp3awaddr, 32
  input :saxihp3awburst, 2
  input :saxihp3awcache, 4
  input :saxihp3awid, 6
  input :saxihp3awlen, 4
  input :saxihp3awlock, 2
  input :saxihp3awprot, 3
  input :saxihp3awqos, 4
  output :saxihp3awready, 1
  input :saxihp3awsize, 2
  input :saxihp3awvalid, 1
  output :saxihp3bid, 6
  input :saxihp3bready, 1
  output :saxihp3bresp, 2
  output :saxihp3bvalid, 1
  output :saxihp3racount, 3
  output :saxihp3rcount, 8
  output :saxihp3rdata, 64
  input :saxihp3rdissuecap1en, 1
  output :saxihp3rid, 6
  output :saxihp3rlast, 1
  input :saxihp3rready, 1
  output :saxihp3rresp, 2
  output :saxihp3rvalid, 1
  output :saxihp3wacount, 6
  output :saxihp3wcount, 8
  input :saxihp3wdata, 64
  input :saxihp3wid, 6
  input :saxihp3wlast, 1
  output :saxihp3wready, 1
  input :saxihp3wrissuecap1en, 1
  input :saxihp3wstrb, 8
  input :saxihp3wvalid, 1

  wire :fclk_clk_bus, 4
  wire :fclk_resetn_bus, 4

  comb do
    fclk_clk0 = fclk_clk_bus[0..0]
    fclk_reset0_n = fclk_resetn_bus[0..0]
  end

  # keep="true": a PS7 with nothing connected must still survive synthesis.
  blackbox :ps7, "PS7",
    attrs: [keep: "true"],
    ports: [
      FCLKCLK: :fclk_clk_bus,
      FCLKRESETN: :fclk_resetn_bus,
      MAXIGP0ACLK: :maxigp0aclk,
      MAXIGP0ARADDR: :maxigp0araddr,
      MAXIGP0ARBURST: :maxigp0arburst,
      MAXIGP0ARCACHE: :maxigp0arcache,
      MAXIGP0ARESETN: :maxigp0aresetn,
      MAXIGP0ARID: :maxigp0arid,
      MAXIGP0ARLEN: :maxigp0arlen,
      MAXIGP0ARLOCK: :maxigp0arlock,
      MAXIGP0ARPROT: :maxigp0arprot,
      MAXIGP0ARQOS: :maxigp0arqos,
      MAXIGP0ARREADY: :maxigp0arready,
      MAXIGP0ARSIZE: :maxigp0arsize,
      MAXIGP0ARVALID: :maxigp0arvalid,
      MAXIGP0AWADDR: :maxigp0awaddr,
      MAXIGP0AWBURST: :maxigp0awburst,
      MAXIGP0AWCACHE: :maxigp0awcache,
      MAXIGP0AWID: :maxigp0awid,
      MAXIGP0AWLEN: :maxigp0awlen,
      MAXIGP0AWLOCK: :maxigp0awlock,
      MAXIGP0AWPROT: :maxigp0awprot,
      MAXIGP0AWQOS: :maxigp0awqos,
      MAXIGP0AWREADY: :maxigp0awready,
      MAXIGP0AWSIZE: :maxigp0awsize,
      MAXIGP0AWVALID: :maxigp0awvalid,
      MAXIGP0BID: :maxigp0bid,
      MAXIGP0BREADY: :maxigp0bready,
      MAXIGP0BRESP: :maxigp0bresp,
      MAXIGP0BVALID: :maxigp0bvalid,
      MAXIGP0RDATA: :maxigp0rdata,
      MAXIGP0RID: :maxigp0rid,
      MAXIGP0RLAST: :maxigp0rlast,
      MAXIGP0RREADY: :maxigp0rready,
      MAXIGP0RRESP: :maxigp0rresp,
      MAXIGP0RVALID: :maxigp0rvalid,
      MAXIGP0WDATA: :maxigp0wdata,
      MAXIGP0WID: :maxigp0wid,
      MAXIGP0WLAST: :maxigp0wlast,
      MAXIGP0WREADY: :maxigp0wready,
      MAXIGP0WSTRB: :maxigp0wstrb,
      MAXIGP0WVALID: :maxigp0wvalid,
      SAXIACPACLK: :saxiacpaclk,
      SAXIACPARADDR: :saxiacparaddr,
      SAXIACPARBURST: :saxiacparburst,
      SAXIACPARCACHE: :saxiacparcache,
      SAXIACPARESETN: :saxiacparesetn,
      SAXIACPARID: :saxiacparid,
      SAXIACPARLEN: :saxiacparlen,
      SAXIACPARLOCK: :saxiacparlock,
      SAXIACPARPROT: :saxiacparprot,
      SAXIACPARQOS: :saxiacparqos,
      SAXIACPARREADY: :saxiacparready,
      SAXIACPARSIZE: :saxiacparsize,
      SAXIACPARUSER: :saxiacparuser,
      SAXIACPARVALID: :saxiacparvalid,
      SAXIACPAWADDR: :saxiacpawaddr,
      SAXIACPAWBURST: :saxiacpawburst,
      SAXIACPAWCACHE: :saxiacpawcache,
      SAXIACPAWID: :saxiacpawid,
      SAXIACPAWLEN: :saxiacpawlen,
      SAXIACPAWLOCK: :saxiacpawlock,
      SAXIACPAWPROT: :saxiacpawprot,
      SAXIACPAWQOS: :saxiacpawqos,
      SAXIACPAWREADY: :saxiacpawready,
      SAXIACPAWSIZE: :saxiacpawsize,
      SAXIACPAWUSER: :saxiacpawuser,
      SAXIACPAWVALID: :saxiacpawvalid,
      SAXIACPBID: :saxiacpbid,
      SAXIACPBREADY: :saxiacpbready,
      SAXIACPBRESP: :saxiacpbresp,
      SAXIACPBVALID: :saxiacpbvalid,
      SAXIACPRDATA: :saxiacprdata,
      SAXIACPRID: :saxiacprid,
      SAXIACPRLAST: :saxiacprlast,
      SAXIACPRREADY: :saxiacprready,
      SAXIACPRRESP: :saxiacprresp,
      SAXIACPRVALID: :saxiacprvalid,
      SAXIACPWDATA: :saxiacpwdata,
      SAXIACPWID: :saxiacpwid,
      SAXIACPWLAST: :saxiacpwlast,
      SAXIACPWREADY: :saxiacpwready,
      SAXIACPWSTRB: :saxiacpwstrb,
      SAXIACPWVALID: :saxiacpwvalid,
      SAXIGP0ACLK: :saxigp0aclk,
      SAXIGP0ARADDR: :saxigp0araddr,
      SAXIGP0ARBURST: :saxigp0arburst,
      SAXIGP0ARCACHE: :saxigp0arcache,
      SAXIGP0ARESETN: :saxigp0aresetn,
      SAXIGP0ARID: :saxigp0arid,
      SAXIGP0ARLEN: :saxigp0arlen,
      SAXIGP0ARLOCK: :saxigp0arlock,
      SAXIGP0ARPROT: :saxigp0arprot,
      SAXIGP0ARQOS: :saxigp0arqos,
      SAXIGP0ARREADY: :saxigp0arready,
      SAXIGP0ARSIZE: :saxigp0arsize,
      SAXIGP0ARVALID: :saxigp0arvalid,
      SAXIGP0AWADDR: :saxigp0awaddr,
      SAXIGP0AWBURST: :saxigp0awburst,
      SAXIGP0AWCACHE: :saxigp0awcache,
      SAXIGP0AWID: :saxigp0awid,
      SAXIGP0AWLEN: :saxigp0awlen,
      SAXIGP0AWLOCK: :saxigp0awlock,
      SAXIGP0AWPROT: :saxigp0awprot,
      SAXIGP0AWQOS: :saxigp0awqos,
      SAXIGP0AWREADY: :saxigp0awready,
      SAXIGP0AWSIZE: :saxigp0awsize,
      SAXIGP0AWVALID: :saxigp0awvalid,
      SAXIGP0BID: :saxigp0bid,
      SAXIGP0BREADY: :saxigp0bready,
      SAXIGP0BRESP: :saxigp0bresp,
      SAXIGP0BVALID: :saxigp0bvalid,
      SAXIGP0RDATA: :saxigp0rdata,
      SAXIGP0RID: :saxigp0rid,
      SAXIGP0RLAST: :saxigp0rlast,
      SAXIGP0RREADY: :saxigp0rready,
      SAXIGP0RRESP: :saxigp0rresp,
      SAXIGP0RVALID: :saxigp0rvalid,
      SAXIGP0WDATA: :saxigp0wdata,
      SAXIGP0WID: :saxigp0wid,
      SAXIGP0WLAST: :saxigp0wlast,
      SAXIGP0WREADY: :saxigp0wready,
      SAXIGP0WSTRB: :saxigp0wstrb,
      SAXIGP0WVALID: :saxigp0wvalid,
      SAXIGP1ACLK: :saxigp1aclk,
      SAXIGP1ARADDR: :saxigp1araddr,
      SAXIGP1ARBURST: :saxigp1arburst,
      SAXIGP1ARCACHE: :saxigp1arcache,
      SAXIGP1ARESETN: :saxigp1aresetn,
      SAXIGP1ARID: :saxigp1arid,
      SAXIGP1ARLEN: :saxigp1arlen,
      SAXIGP1ARLOCK: :saxigp1arlock,
      SAXIGP1ARPROT: :saxigp1arprot,
      SAXIGP1ARQOS: :saxigp1arqos,
      SAXIGP1ARREADY: :saxigp1arready,
      SAXIGP1ARSIZE: :saxigp1arsize,
      SAXIGP1ARVALID: :saxigp1arvalid,
      SAXIGP1AWADDR: :saxigp1awaddr,
      SAXIGP1AWBURST: :saxigp1awburst,
      SAXIGP1AWCACHE: :saxigp1awcache,
      SAXIGP1AWID: :saxigp1awid,
      SAXIGP1AWLEN: :saxigp1awlen,
      SAXIGP1AWLOCK: :saxigp1awlock,
      SAXIGP1AWPROT: :saxigp1awprot,
      SAXIGP1AWQOS: :saxigp1awqos,
      SAXIGP1AWREADY: :saxigp1awready,
      SAXIGP1AWSIZE: :saxigp1awsize,
      SAXIGP1AWVALID: :saxigp1awvalid,
      SAXIGP1BID: :saxigp1bid,
      SAXIGP1BREADY: :saxigp1bready,
      SAXIGP1BRESP: :saxigp1bresp,
      SAXIGP1BVALID: :saxigp1bvalid,
      SAXIGP1RDATA: :saxigp1rdata,
      SAXIGP1RID: :saxigp1rid,
      SAXIGP1RLAST: :saxigp1rlast,
      SAXIGP1RREADY: :saxigp1rready,
      SAXIGP1RRESP: :saxigp1rresp,
      SAXIGP1RVALID: :saxigp1rvalid,
      SAXIGP1WDATA: :saxigp1wdata,
      SAXIGP1WID: :saxigp1wid,
      SAXIGP1WLAST: :saxigp1wlast,
      SAXIGP1WREADY: :saxigp1wready,
      SAXIGP1WSTRB: :saxigp1wstrb,
      SAXIGP1WVALID: :saxigp1wvalid,
      SAXIHP0ACLK: :saxihp0aclk,
      SAXIHP0ARADDR: :saxihp0araddr,
      SAXIHP0ARBURST: :saxihp0arburst,
      SAXIHP0ARCACHE: :saxihp0arcache,
      SAXIHP0ARESETN: :saxihp0aresetn,
      SAXIHP0ARID: :saxihp0arid,
      SAXIHP0ARLEN: :saxihp0arlen,
      SAXIHP0ARLOCK: :saxihp0arlock,
      SAXIHP0ARPROT: :saxihp0arprot,
      SAXIHP0ARQOS: :saxihp0arqos,
      SAXIHP0ARREADY: :saxihp0arready,
      SAXIHP0ARSIZE: :saxihp0arsize,
      SAXIHP0ARVALID: :saxihp0arvalid,
      SAXIHP0AWADDR: :saxihp0awaddr,
      SAXIHP0AWBURST: :saxihp0awburst,
      SAXIHP0AWCACHE: :saxihp0awcache,
      SAXIHP0AWID: :saxihp0awid,
      SAXIHP0AWLEN: :saxihp0awlen,
      SAXIHP0AWLOCK: :saxihp0awlock,
      SAXIHP0AWPROT: :saxihp0awprot,
      SAXIHP0AWQOS: :saxihp0awqos,
      SAXIHP0AWREADY: :saxihp0awready,
      SAXIHP0AWSIZE: :saxihp0awsize,
      SAXIHP0AWVALID: :saxihp0awvalid,
      SAXIHP0BID: :saxihp0bid,
      SAXIHP0BREADY: :saxihp0bready,
      SAXIHP0BRESP: :saxihp0bresp,
      SAXIHP0BVALID: :saxihp0bvalid,
      SAXIHP0RACOUNT: :saxihp0racount,
      SAXIHP0RCOUNT: :saxihp0rcount,
      SAXIHP0RDATA: :saxihp0rdata,
      SAXIHP0RDISSUECAP1EN: :saxihp0rdissuecap1en,
      SAXIHP0RID: :saxihp0rid,
      SAXIHP0RLAST: :saxihp0rlast,
      SAXIHP0RREADY: :saxihp0rready,
      SAXIHP0RRESP: :saxihp0rresp,
      SAXIHP0RVALID: :saxihp0rvalid,
      SAXIHP0WACOUNT: :saxihp0wacount,
      SAXIHP0WCOUNT: :saxihp0wcount,
      SAXIHP0WDATA: :saxihp0wdata,
      SAXIHP0WID: :saxihp0wid,
      SAXIHP0WLAST: :saxihp0wlast,
      SAXIHP0WREADY: :saxihp0wready,
      SAXIHP0WRISSUECAP1EN: :saxihp0wrissuecap1en,
      SAXIHP0WSTRB: :saxihp0wstrb,
      SAXIHP0WVALID: :saxihp0wvalid,
      SAXIHP1ACLK: :saxihp1aclk,
      SAXIHP1ARADDR: :saxihp1araddr,
      SAXIHP1ARBURST: :saxihp1arburst,
      SAXIHP1ARCACHE: :saxihp1arcache,
      SAXIHP1ARESETN: :saxihp1aresetn,
      SAXIHP1ARID: :saxihp1arid,
      SAXIHP1ARLEN: :saxihp1arlen,
      SAXIHP1ARLOCK: :saxihp1arlock,
      SAXIHP1ARPROT: :saxihp1arprot,
      SAXIHP1ARQOS: :saxihp1arqos,
      SAXIHP1ARREADY: :saxihp1arready,
      SAXIHP1ARSIZE: :saxihp1arsize,
      SAXIHP1ARVALID: :saxihp1arvalid,
      SAXIHP1AWADDR: :saxihp1awaddr,
      SAXIHP1AWBURST: :saxihp1awburst,
      SAXIHP1AWCACHE: :saxihp1awcache,
      SAXIHP1AWID: :saxihp1awid,
      SAXIHP1AWLEN: :saxihp1awlen,
      SAXIHP1AWLOCK: :saxihp1awlock,
      SAXIHP1AWPROT: :saxihp1awprot,
      SAXIHP1AWQOS: :saxihp1awqos,
      SAXIHP1AWREADY: :saxihp1awready,
      SAXIHP1AWSIZE: :saxihp1awsize,
      SAXIHP1AWVALID: :saxihp1awvalid,
      SAXIHP1BID: :saxihp1bid,
      SAXIHP1BREADY: :saxihp1bready,
      SAXIHP1BRESP: :saxihp1bresp,
      SAXIHP1BVALID: :saxihp1bvalid,
      SAXIHP1RACOUNT: :saxihp1racount,
      SAXIHP1RCOUNT: :saxihp1rcount,
      SAXIHP1RDATA: :saxihp1rdata,
      SAXIHP1RDISSUECAP1EN: :saxihp1rdissuecap1en,
      SAXIHP1RID: :saxihp1rid,
      SAXIHP1RLAST: :saxihp1rlast,
      SAXIHP1RREADY: :saxihp1rready,
      SAXIHP1RRESP: :saxihp1rresp,
      SAXIHP1RVALID: :saxihp1rvalid,
      SAXIHP1WACOUNT: :saxihp1wacount,
      SAXIHP1WCOUNT: :saxihp1wcount,
      SAXIHP1WDATA: :saxihp1wdata,
      SAXIHP1WID: :saxihp1wid,
      SAXIHP1WLAST: :saxihp1wlast,
      SAXIHP1WREADY: :saxihp1wready,
      SAXIHP1WRISSUECAP1EN: :saxihp1wrissuecap1en,
      SAXIHP1WSTRB: :saxihp1wstrb,
      SAXIHP1WVALID: :saxihp1wvalid,
      SAXIHP2ACLK: :saxihp2aclk,
      SAXIHP2ARADDR: :saxihp2araddr,
      SAXIHP2ARBURST: :saxihp2arburst,
      SAXIHP2ARCACHE: :saxihp2arcache,
      SAXIHP2ARESETN: :saxihp2aresetn,
      SAXIHP2ARID: :saxihp2arid,
      SAXIHP2ARLEN: :saxihp2arlen,
      SAXIHP2ARLOCK: :saxihp2arlock,
      SAXIHP2ARPROT: :saxihp2arprot,
      SAXIHP2ARQOS: :saxihp2arqos,
      SAXIHP2ARREADY: :saxihp2arready,
      SAXIHP2ARSIZE: :saxihp2arsize,
      SAXIHP2ARVALID: :saxihp2arvalid,
      SAXIHP2AWADDR: :saxihp2awaddr,
      SAXIHP2AWBURST: :saxihp2awburst,
      SAXIHP2AWCACHE: :saxihp2awcache,
      SAXIHP2AWID: :saxihp2awid,
      SAXIHP2AWLEN: :saxihp2awlen,
      SAXIHP2AWLOCK: :saxihp2awlock,
      SAXIHP2AWPROT: :saxihp2awprot,
      SAXIHP2AWQOS: :saxihp2awqos,
      SAXIHP2AWREADY: :saxihp2awready,
      SAXIHP2AWSIZE: :saxihp2awsize,
      SAXIHP2AWVALID: :saxihp2awvalid,
      SAXIHP2BID: :saxihp2bid,
      SAXIHP2BREADY: :saxihp2bready,
      SAXIHP2BRESP: :saxihp2bresp,
      SAXIHP2BVALID: :saxihp2bvalid,
      SAXIHP2RACOUNT: :saxihp2racount,
      SAXIHP2RCOUNT: :saxihp2rcount,
      SAXIHP2RDATA: :saxihp2rdata,
      SAXIHP2RDISSUECAP1EN: :saxihp2rdissuecap1en,
      SAXIHP2RID: :saxihp2rid,
      SAXIHP2RLAST: :saxihp2rlast,
      SAXIHP2RREADY: :saxihp2rready,
      SAXIHP2RRESP: :saxihp2rresp,
      SAXIHP2RVALID: :saxihp2rvalid,
      SAXIHP2WACOUNT: :saxihp2wacount,
      SAXIHP2WCOUNT: :saxihp2wcount,
      SAXIHP2WDATA: :saxihp2wdata,
      SAXIHP2WID: :saxihp2wid,
      SAXIHP2WLAST: :saxihp2wlast,
      SAXIHP2WREADY: :saxihp2wready,
      SAXIHP2WRISSUECAP1EN: :saxihp2wrissuecap1en,
      SAXIHP2WSTRB: :saxihp2wstrb,
      SAXIHP2WVALID: :saxihp2wvalid,
      SAXIHP3ACLK: :saxihp3aclk,
      SAXIHP3ARADDR: :saxihp3araddr,
      SAXIHP3ARBURST: :saxihp3arburst,
      SAXIHP3ARCACHE: :saxihp3arcache,
      SAXIHP3ARESETN: :saxihp3aresetn,
      SAXIHP3ARID: :saxihp3arid,
      SAXIHP3ARLEN: :saxihp3arlen,
      SAXIHP3ARLOCK: :saxihp3arlock,
      SAXIHP3ARPROT: :saxihp3arprot,
      SAXIHP3ARQOS: :saxihp3arqos,
      SAXIHP3ARREADY: :saxihp3arready,
      SAXIHP3ARSIZE: :saxihp3arsize,
      SAXIHP3ARVALID: :saxihp3arvalid,
      SAXIHP3AWADDR: :saxihp3awaddr,
      SAXIHP3AWBURST: :saxihp3awburst,
      SAXIHP3AWCACHE: :saxihp3awcache,
      SAXIHP3AWID: :saxihp3awid,
      SAXIHP3AWLEN: :saxihp3awlen,
      SAXIHP3AWLOCK: :saxihp3awlock,
      SAXIHP3AWPROT: :saxihp3awprot,
      SAXIHP3AWQOS: :saxihp3awqos,
      SAXIHP3AWREADY: :saxihp3awready,
      SAXIHP3AWSIZE: :saxihp3awsize,
      SAXIHP3AWVALID: :saxihp3awvalid,
      SAXIHP3BID: :saxihp3bid,
      SAXIHP3BREADY: :saxihp3bready,
      SAXIHP3BRESP: :saxihp3bresp,
      SAXIHP3BVALID: :saxihp3bvalid,
      SAXIHP3RACOUNT: :saxihp3racount,
      SAXIHP3RCOUNT: :saxihp3rcount,
      SAXIHP3RDATA: :saxihp3rdata,
      SAXIHP3RDISSUECAP1EN: :saxihp3rdissuecap1en,
      SAXIHP3RID: :saxihp3rid,
      SAXIHP3RLAST: :saxihp3rlast,
      SAXIHP3RREADY: :saxihp3rready,
      SAXIHP3RRESP: :saxihp3rresp,
      SAXIHP3RVALID: :saxihp3rvalid,
      SAXIHP3WACOUNT: :saxihp3wacount,
      SAXIHP3WCOUNT: :saxihp3wcount,
      SAXIHP3WDATA: :saxihp3wdata,
      SAXIHP3WID: :saxihp3wid,
      SAXIHP3WLAST: :saxihp3wlast,
      SAXIHP3WREADY: :saxihp3wready,
      SAXIHP3WRISSUECAP1EN: :saxihp3wrissuecap1en,
      SAXIHP3WSTRB: :saxihp3wstrb,
      SAXIHP3WVALID: :saxihp3wvalid
    ]
end
