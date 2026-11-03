defmodule Hw.AxiTransactor do
  @moduledoc """
  Register-driven AXI3 master: one transfer per strobe, every field from a
  configuration register, every response latched. Built to put each pin of
  a PS7 slave port (S_AXI_GP/HP/ACP) under software control, one handshake
  at a time, so a test can tell a stuck pin from a working one.

  ## Configuration (registers, held by the instantiator)

      awaddr / araddr        address
      awctl / arctl          [5:0] ID, [9:6] LEN, [11:10] SIZE, [13:12] BURST,
                             [15:14] LOCK, [19:16] CACHE, [22:20] PROT,
                             [26:23] QOS, [31:27] USER (ACP only)
      wlo / whi              WDATA[31:0] / [63:32]
      wctl                   [7:0] WSTRB, [13:8] WID, [14] WLAST
      misc                   [0] RDISSUECAP1_EN, [1] WRISSUECAP1_EN,
                             [2] BREADY, [3] RREADY

  ## Strobes (one `aclk` cycle each)

      go_aw / go_w / go_ar   raise AWVALID / WVALID / ARVALID, held until
                             the matching READY; then dropped
      clr                    zero the counters and the read accumulator

  ## Results

      r0  [5:0] last BID, [7:6] last BRESP, [15:8] B count,
          [23:16] AW count, [31:24] W count
      r1 / r2  last RDATA[31:0] / [63:32]
      r3  [5:0] last RID, [7:6] last RRESP, [8] last RLAST,
          [23:16] R beat count, [31:24] AR count
      r4  levels now: [0] AWREADY, [1] WREADY, [2] ARREADY, [3] ARESETN,
          [4] BVALID, [5] RVALID, [6] AWVALID, [7] WVALID, [8] ARVALID
      r5  HP FIFO counts: [2:0] RACOUNT, [15:8] RCOUNT, [21:16] WACOUNT,
          [31:24] WCOUNT
      r6 / r7  XOR of every RDATA beat accepted, [31:0] / [63:32]
  """

  use Hw.Component

  clock :aclk, freq: 100.0
  input :rst, 1

  input :awaddr, 32
  input :awctl, 32
  input :wlo, 32
  input :whi, 32
  input :wctl, 32
  input :araddr, 32
  input :arctl, 32
  input :misc, 32
  input :go_aw, 1
  input :go_w, 1
  input :go_ar, 1
  input :clr, 1

  output :m_awid, 6
  output :m_awaddr, 32
  output :m_awlen, 4
  output :m_awsize, 2
  output :m_awburst, 2
  output :m_awlock, 2
  output :m_awcache, 4
  output :m_awprot, 3
  output :m_awqos, 4
  output :m_awuser, 5
  output :m_awvalid, 1
  input :m_awready, 1

  output :m_wid, 6
  output :m_wdata, 64
  output :m_wstrb, 8
  output :m_wlast, 1
  output :m_wvalid, 1
  input :m_wready, 1

  input :m_bid, 6
  input :m_bresp, 2
  input :m_bvalid, 1
  output :m_bready, 1

  output :m_arid, 6
  output :m_araddr, 32
  output :m_arlen, 4
  output :m_arsize, 2
  output :m_arburst, 2
  output :m_arlock, 2
  output :m_arcache, 4
  output :m_arprot, 3
  output :m_arqos, 4
  output :m_aruser, 5
  output :m_arvalid, 1
  input :m_arready, 1

  input :m_rid, 6
  input :m_rdata, 64
  input :m_rresp, 2
  input :m_rlast, 1
  input :m_rvalid, 1
  output :m_rready, 1

  output :m_rdissuecap1en, 1
  output :m_wrissuecap1en, 1
  input :m_aresetn, 1
  input :m_racount, 3
  input :m_rcount, 8
  input :m_wacount, 6
  input :m_wcount, 8

  output :r0, 32
  output :r1, 32
  output :r2, 32
  output :r3, 32
  output :r4, 32
  output :r5, 32
  output :r6, 32
  output :r7, 32

  wire :awv, 1, init: 0
  wire :wv, 1, init: 0
  wire :arv, 1, init: 0
  wire :bid_q, 6, init: 0
  wire :bresp_q, 2, init: 0
  wire :rid_q, 6, init: 0
  wire :rresp_q, 2, init: 0
  wire :rlast_q, 1, init: 0
  wire :rdata_q, 64, init: 0
  wire :rxor, 64, init: 0
  wire :b_count, 8, init: 0
  wire :aw_count, 8, init: 0
  wire :w_count, 8, init: 0
  wire :r_count, 8, init: 0
  wire :ar_count, 8, init: 0
  wire :pad1, 1
  wire :pad2, 2
  wire :pad5, 5
  wire :pad6, 6
  wire :pad7, 7
  wire :pad23, 23

  comb do
    pad1 = 0
    pad2 = 0
    pad5 = 0
    pad6 = 0
    pad7 = 0
    pad23 = 0

    m_awaddr = awaddr
    m_awid = awctl[5..0]
    m_awlen = awctl[9..6]
    m_awsize = awctl[11..10]
    m_awburst = awctl[13..12]
    m_awlock = awctl[15..14]
    m_awcache = awctl[19..16]
    m_awprot = awctl[22..20]
    m_awqos = awctl[26..23]
    m_awuser = awctl[31..27]
    m_awvalid = awv

    m_wdata = {whi, wlo}
    m_wstrb = wctl[7..0]
    m_wid = wctl[13..8]
    m_wlast = wctl[14..14]
    m_wvalid = wv

    m_araddr = araddr
    m_arid = arctl[5..0]
    m_arlen = arctl[9..6]
    m_arsize = arctl[11..10]
    m_arburst = arctl[13..12]
    m_arlock = arctl[15..14]
    m_arcache = arctl[19..16]
    m_arprot = arctl[22..20]
    m_arqos = arctl[26..23]
    m_aruser = arctl[31..27]
    m_arvalid = arv

    m_rdissuecap1en = misc[0..0]
    m_wrissuecap1en = misc[1..1]
    m_bready = misc[2..2]
    m_rready = misc[3..3]

    r0 = {w_count, aw_count, b_count, bresp_q, bid_q}
    r1 = rdata_q[31..0]
    r2 = rdata_q[63..32]
    r3 = {ar_count, r_count, pad7, rlast_q, rresp_q, rid_q}
    r4 = {pad23, arv, wv, awv, m_rvalid, m_bvalid, m_aresetn, m_arready, m_wready, m_awready}
    r5 = {m_wcount, pad2, m_wacount, m_rcount, pad5, m_racount}
    r6 = rxor[31..0]
    r7 = rxor[63..32]
  end

  # AW / W / AR: VALID from the strobe until the handshake.
  on :aclk do
    if rst == 1 do
      awv = 0
      wv = 0
      arv = 0
    else
      if awv == 1 and m_awready == 1 do
        awv = 0
      else
        if go_aw == 1 do
          awv = 1
        end
      end

      if wv == 1 and m_wready == 1 do
        wv = 0
      else
        if go_w == 1 do
          wv = 1
        end
      end

      if arv == 1 and m_arready == 1 do
        arv = 0
      else
        if go_ar == 1 do
          arv = 1
        end
      end
    end
  end

  # Counters, response latches, read accumulator.
  on :aclk do
    if rst == 1 or clr == 1 do
      aw_count = 0
      w_count = 0
      ar_count = 0
      b_count = 0
      r_count = 0
      rxor = 0
    else
      if awv == 1 and m_awready == 1 do
        aw_count = aw_count + 1
      end

      if wv == 1 and m_wready == 1 do
        w_count = w_count + 1
      end

      if arv == 1 and m_arready == 1 do
        ar_count = ar_count + 1
      end

      if m_bvalid == 1 and misc[2..2] == 1 do
        b_count = b_count + 1
        bid_q = m_bid
        bresp_q = m_bresp
      end

      if m_rvalid == 1 and misc[3..3] == 1 do
        r_count = r_count + 1
        rid_q = m_rid
        rresp_q = m_rresp
        rlast_q = m_rlast
        rdata_q = m_rdata
        rxor = bxor(rxor, m_rdata)
      end
    end
  end
end
