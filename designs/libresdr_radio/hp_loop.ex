defmodule LibreSDRRadio.HPLoop.Top do
  @moduledoc """
  HP0 loopback gate for the TX direction: DDR -> PL -> DDR, nothing else.

      TX ring (0x3FD0_0000, 1 MB)  --HP0 AR/R-->  Hw.AXIHPReader
          --> 1024 x 64 BRAM FIFO (single clock)
          --> Hw.AXIHPWriter  --HP0 AW/W/B-->  RX ring (0x3FF0_0000, 1 MB)

  The first silicon test of `Hw.AXIHPReader` and of `Hw.PS7HP`'s read
  channel. No AD9363, no pins, no LVDS: this top has no I/O at all, which
  keeps it far from the routing cliff `LibreSDRRadio.Top` lives on and
  isolates the one question — does a PL-mastered HP0 read return what the
  ARM wrote, in order, at rate — from everything the radio adds. Pass:
  the RX ring holds a byte-exact copy of what software put in the TX ring,
  `rresp_errs`/`rlast_errs`/`bresp_errs` stay 0, and burst counts match.

  Both rings are existing `no-map` reservations (nervezynq notes/ocusync/
  09: TX 0x3FD0_0000 + 1 MB, RX = the top 1 MB of DmaBuf at 0x3FF0_0000),
  so this needs no device-tree change.

  ## EMIO control (PS -> PL, `emio_gpio_o`)

      [0]      reader enable         (issue AR bursts while head is ahead)
      [1]      writer enable         (drain the FIFO into the RX ring)
      [2]      run: 0 holds both engines and the FIFO in reset
      [63:32]  head_addr, absolute   (bank 3; producer doorbell)

  Rules: drop `run` only while both enables are low and the burst counters
  have stopped moving (an AXI master must not be reset mid-burst). Publish
  `head_addr` on 128 B boundaries (Hw.AXIHPReader's producer rule).
  `head_addr` crosses from the PS GPIO block as 32 parallel bits; it is
  double-synchronised and only accepted once two consecutive samples
  agree, so a sample torn across a GPIO write is never used.

  ## EMIO status (PL -> PS, `emio_gpio_i`)

      [15:0]   reader bursts          [31:16]  writer bursts
      [47:32]  reader read_ptr[19:4]  [51:48]  reader rresp_errs[3:0]
      [55:52]  reader rlast_errs[3:0] [59:56]  writer bresp_errs[3:0]
      [60]     heartbeat[23]          [61]     alive (reads 1 out of reset)
      [62]     must read 1            [63]     must read 0

  ## No GP0 slave

  M_AXI_GP0's ready inputs are tied low: there is no AXI-lite register
  file in this top. Never touch 0x4000_0000 with this bitstream loaded —
  a PS access there never completes and wedges the CPU (build.exs's
  standing warning). Everything goes over EMIO.

  Bits 61..63 are the smoke test, as in `LibreSDRRadio.Top`: prove the
  EMIO read path before trusting any DMA field.
  """

  use Hw.Component

  # --- clocks / reset -----------------------------------------------------------
  wire :fclk_clk0, 1
  wire :fclk_reset0_n, 1
  wire :axi_clk, 1

  clock :axi_clk, freq: 100.0

  wire :zero, 1
  wire :one, 1
  # GP0 slave-side inputs, tied: this top has no AXI-lite slave.
  wire :gp_id_tie, 12
  wire :gp_resp_tie, 2
  wire :gp_rdata_tie, 32
  wire :axi_rst, 1
  wire :heartbeat, 24, init: 0

  # --- EMIO ---------------------------------------------------------------------
  wire :emio_in, 64
  wire :emio_out, 64

  wire :rd_enable, 1
  wire :wr_enable, 1
  wire :run, 1
  wire :eng_resetn, 1
  wire :head_raw, 32
  wire :head_s0, 32, init: 0
  wire :head_s1, 32, init: 0
  wire :head_q, 32, init: 0

  # --- ring constants ----------------------------------------------------------------
  wire :tx_base, 32
  wire :rx_base, 32
  wire :ring_size, 32

  # --- HP0 write side (writer) ------------------------------------------------------
  wire :hp_awid, 6
  wire :hp_awaddr, 32
  wire :hp_awlen, 4
  wire :hp_awsize, 2
  wire :hp_awburst, 2
  wire :hp_awlock, 2
  wire :hp_awcache, 4
  wire :hp_awprot, 3
  wire :hp_awqos, 4
  wire :hp_awvalid, 1
  wire :hp_awready, 1
  wire :hp_wid, 6
  wire :hp_wdata, 64
  wire :hp_wstrb, 8
  wire :hp_wlast, 1
  wire :hp_wvalid, 1
  wire :hp_wready, 1
  wire :hp_bid, 6
  wire :hp_bresp, 2
  wire :hp_bvalid, 1
  wire :hp_bready, 1

  # --- HP0 read side (reader) --------------------------------------------------------
  wire :hp_arid, 6
  wire :hp_araddr, 32
  wire :hp_arlen, 4
  wire :hp_arsize, 2
  wire :hp_arburst, 2
  wire :hp_arlock, 2
  wire :hp_arcache, 4
  wire :hp_arprot, 3
  wire :hp_arqos, 4
  wire :hp_arvalid, 1
  wire :hp_arready, 1
  wire :hp_rid, 6
  wire :hp_rdata, 64
  wire :hp_rresp, 2
  wire :hp_rlast, 1
  wire :hp_rvalid, 1
  wire :hp_rready, 1

  # --- engine status ------------------------------------------------------------------
  wire :rd_read_ptr, 32
  wire :rd_bursts, 16
  wire :rd_rresp_errs, 8
  wire :rd_rlast_errs, 8
  wire :wr_write_ptr, 32
  wire :wr_bursts, 16
  wire :wr_bresp_errs, 8
  wire :rptr_lo, 16
  wire :rresp_lo, 4
  wire :rlast_lo, 4
  wire :bresp_lo, 4
  wire :hb_bit, 1

  # --- FIFO between the engines ----------------------------------------------------------
  # Single clock, so no CDC: the same shape as LibreSDRRadio.Top's sbuf with
  # the gray-pointer crossing removed. 1024 x 64 = two RAMB36 side by side,
  # no depth cascade (see top.ex on why that matters here).
  memory :lbuf, width: 64, depth: 1024, sync_read: :axi_clk

  wire :rd_m_data, 64
  wire :rd_m_wen, 1
  wire :rd_m_space, 1
  wire :lb_wr_ptr, 11, init: 0
  wire :lb_rd_ptr, 11, init: 0
  wire :lb_wr_idx, 10
  wire :lb_rd_idx, 10
  wire :lb_count, 11
  wire :lb_rd_en, 1
  wire :lb_rd_data, 64
  wire :wr_s_avail, 1

  instance :clkbuf, Hw.Xilinx.BUFG,
    i: :fclk_clk0,
    o: :axi_clk

  instance :ps, Hw.PS7HP,
    fclk_clk0: :fclk_clk0,
    fclk_reset0_n: :fclk_reset0_n,
    maxigp0_aclk: :axi_clk,
    maxigp0_awready: :zero,
    maxigp0_wready: :zero,
    maxigp0_bid: :gp_id_tie,
    maxigp0_bresp: :gp_resp_tie,
    maxigp0_bvalid: :zero,
    maxigp0_arready: :zero,
    maxigp0_rid: :gp_id_tie,
    maxigp0_rdata: :gp_rdata_tie,
    maxigp0_rresp: :gp_resp_tie,
    maxigp0_rlast: :zero,
    maxigp0_rvalid: :zero,
    saxihp0_aclk: :axi_clk,
    saxihp0_awid: :hp_awid,
    saxihp0_awaddr: :hp_awaddr,
    saxihp0_awlen: :hp_awlen,
    saxihp0_awsize: :hp_awsize,
    saxihp0_awburst: :hp_awburst,
    saxihp0_awlock: :hp_awlock,
    saxihp0_awcache: :hp_awcache,
    saxihp0_awprot: :hp_awprot,
    saxihp0_awqos: :hp_awqos,
    saxihp0_awvalid: :hp_awvalid,
    saxihp0_awready: :hp_awready,
    saxihp0_wid: :hp_wid,
    saxihp0_wdata: :hp_wdata,
    saxihp0_wstrb: :hp_wstrb,
    saxihp0_wlast: :hp_wlast,
    saxihp0_wvalid: :hp_wvalid,
    saxihp0_wready: :hp_wready,
    saxihp0_bid: :hp_bid,
    saxihp0_bresp: :hp_bresp,
    saxihp0_bvalid: :hp_bvalid,
    saxihp0_bready: :hp_bready,
    saxihp0_arid: :hp_arid,
    saxihp0_araddr: :hp_araddr,
    saxihp0_arlen: :hp_arlen,
    saxihp0_arsize: :hp_arsize,
    saxihp0_arburst: :hp_arburst,
    saxihp0_arlock: :hp_arlock,
    saxihp0_arcache: :hp_arcache,
    saxihp0_arprot: :hp_arprot,
    saxihp0_arqos: :hp_arqos,
    saxihp0_arvalid: :hp_arvalid,
    saxihp0_arready: :hp_arready,
    saxihp0_rid: :hp_rid,
    saxihp0_rdata: :hp_rdata,
    saxihp0_rresp: :hp_rresp,
    saxihp0_rlast: :hp_rlast,
    saxihp0_rvalid: :hp_rvalid,
    saxihp0_rready: :hp_rready,
    emio_gpio_i: :emio_in,
    emio_gpio_o: :emio_out

  instance :rd, Hw.AXIHPReader,
    BURST_LEN: 16,
    aclk: :axi_clk,
    aresetn: :eng_resetn,
    m_data: :rd_m_data,
    m_wen: :rd_m_wen,
    m_space: :rd_m_space,
    base_addr: :tx_base,
    ring_size: :ring_size,
    head_addr: :head_q,
    enable: :rd_enable,
    read_ptr: :rd_read_ptr,
    bursts: :rd_bursts,
    rresp_errs: :rd_rresp_errs,
    rlast_errs: :rd_rlast_errs,
    m_axi_arid: :hp_arid,
    m_axi_araddr: :hp_araddr,
    m_axi_arlen: :hp_arlen,
    m_axi_arsize: :hp_arsize,
    m_axi_arburst: :hp_arburst,
    m_axi_arlock: :hp_arlock,
    m_axi_arcache: :hp_arcache,
    m_axi_arprot: :hp_arprot,
    m_axi_arqos: :hp_arqos,
    m_axi_arvalid: :hp_arvalid,
    m_axi_arready: :hp_arready,
    m_axi_rid: :hp_rid,
    m_axi_rdata: :hp_rdata,
    m_axi_rresp: :hp_rresp,
    m_axi_rlast: :hp_rlast,
    m_axi_rvalid: :hp_rvalid,
    m_axi_rready: :hp_rready

  # PIPELINED_SOURCE: the BRAM read is strobed, word arrives next cycle —
  # identical to LibreSDRRadio.Top's use of the writer.
  instance :wr, Hw.AXIHPWriter,
    BURST_LEN: 16,
    PIPELINED_SOURCE: 1,
    aclk: :axi_clk,
    aresetn: :eng_resetn,
    s_data: :lb_rd_data,
    s_avail: :wr_s_avail,
    s_ren: :lb_rd_en,
    base_addr: :rx_base,
    ring_size: :ring_size,
    enable: :wr_enable,
    write_ptr: :wr_write_ptr,
    bursts: :wr_bursts,
    bresp_errs: :wr_bresp_errs,
    m_axi_awid: :hp_awid,
    m_axi_awaddr: :hp_awaddr,
    m_axi_awlen: :hp_awlen,
    m_axi_awsize: :hp_awsize,
    m_axi_awburst: :hp_awburst,
    m_axi_awlock: :hp_awlock,
    m_axi_awcache: :hp_awcache,
    m_axi_awprot: :hp_awprot,
    m_axi_awqos: :hp_awqos,
    m_axi_awvalid: :hp_awvalid,
    m_axi_awready: :hp_awready,
    m_axi_wid: :hp_wid,
    m_axi_wdata: :hp_wdata,
    m_axi_wstrb: :hp_wstrb,
    m_axi_wlast: :hp_wlast,
    m_axi_wvalid: :hp_wvalid,
    m_axi_wready: :hp_wready,
    m_axi_bid: :hp_bid,
    m_axi_bresp: :hp_bresp,
    m_axi_bvalid: :hp_bvalid,
    m_axi_bready: :hp_bready

  comb do
    zero = 0
    one = 1
    gp_id_tie = 0
    gp_resp_tie = 0
    gp_rdata_tie = 0
    axi_rst = bnot(fclk_reset0_n)

    tx_base = 0x3FD00000
    rx_base = 0x3FF00000
    ring_size = 0x00100000

    rd_enable = emio_out[0..0]
    wr_enable = emio_out[1..1]
    run = emio_out[2..2]
    head_raw = emio_out[63..32]
    eng_resetn = band(fclk_reset0_n, run)

    # FIFO: m_space promises a whole burst (Hw.AXIHPReader's contract);
    # s_avail promises a whole burst resident (Hw.AXIHPWriter's).
    lb_wr_idx = lb_wr_ptr[9..0]
    lb_rd_idx = lb_rd_ptr[9..0]
    lb_count = lb_wr_ptr - lb_rd_ptr
    rd_m_space = lb_count <= 1008
    wr_s_avail = lb_count >= 16
    lb_rd_data = lbuf[lb_rd_idx]

    rptr_lo = rd_read_ptr[19..4]
    rresp_lo = rd_rresp_errs[3..0]
    rlast_lo = rd_rlast_errs[3..0]
    bresp_lo = wr_bresp_errs[3..0]
    hb_bit = heartbeat[23..23]

    emio_in = {zero, one, fclk_reset0_n, hb_bit, bresp_lo, rlast_lo, rresp_lo,
               rptr_lo, wr_bursts, rd_bursts}
  end

  on :axi_clk do
    if axi_rst == 1 do
      heartbeat = 0
    else
      heartbeat = heartbeat + 1
    end
  end

  # head_addr crossing: 2-flop sync, then accept only a value seen on two
  # consecutive edges. The GPIO block updates all 32 bits together, so a
  # torn sample differs from its successor and is never accepted.
  on :axi_clk do
    head_s0 = head_raw
    head_s1 = head_s0
    if head_s1 == head_s0 do
      head_q = head_s1
    end
  end

  # FIFO write port (reader side) and read pointer (writer side). Held
  # empty while `run` is low.
  on :axi_clk do
    if eng_resetn == 0 do
      lb_wr_ptr = 0
      lb_rd_ptr = 0
    else
      if rd_m_wen == 1 do
        lbuf[lb_wr_idx] = rd_m_data
        lb_wr_ptr = lb_wr_ptr + 1
      end
      if lb_rd_en == 1 and lb_count != 0 do
        lb_rd_ptr = lb_rd_ptr + 1
      end
    end
  end
end
