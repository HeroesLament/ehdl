defmodule LibreSDRRadio.Top do

  # Input-delay tap for every receive lane, in IDELAYE2 taps (0..31).
  # FIXED type, so this is baked into the bitstream: sweeping it means
  # rebuilding. Override at build time with IDELAY_TAP=<n>.
  @idelay_tap (System.get_env("IDELAY_TAP") || "0") |> String.to_integer()
  @moduledoc """
  AD9363 control plane: the PS7 bring-up design plus an SPI master wired to the
  transceiver, so the radio can be configured from Elixir.

  ## The SPI master is a byte pipe, deliberately

  `Hw.SPI.Master` moves one byte per transfer with a chip-select hold bit, and
  knows nothing about the AD936x command grammar. This design exposes exactly
  that through AXI: write a byte, say whether to keep CS asserted, poll for
  completion, read what came back.

  The 24-bit AD936x transaction — `{R/W, W1, W0, addr[12:8]}`, `addr[7:0]`,
  `data` — is assembled in Elixir, not here. That is worth being explicit
  about, because the framing is the single most likely thing to be wrong on
  first contact, and getting it wrong should cost a recompile of a module, not
  a synthesis, place, route, bitstream and reboot cycle. If the first read
  comes back as garbage we can try three variants in a minute.

  ## Register map (via `Hw.AXI4Lite.Slave`)

      CTRL0   [7:0]  spi tx byte
              [8]    cs_hold — keep CS asserted after this byte
              [9]    go — a TOGGLE, not a strobe
      CTRL1   [0]    ad9363 RESETB   (active low, so 0 = held in reset)
              [1]    ad9363 ENABLE
              [2]    ad9363 TXNRX
              [3]    ad9363 EN_AGC
      STATUS0 [7:0]  last byte shifted in
              [8]    done — a TOGGLE, flips on each completed byte
              [9]    spi tx_ready (master idle)
      STATUS1 [23:0] heartbeat

  ### Why `go` and `done` are toggles

  An AXI-Lite register holds its value; it has no notion of a write pulse. A
  `start` bit would have to be cleared by something, and the only two
  candidates both lose: clearing it from the fabric means two writers race for
  one register, and clearing it from Elixir means a second AXI round trip in
  which the transfer may already have completed and been missed.

  A toggle has neither problem. Elixir flips the bit, the fabric edge-detects
  the change against a shadow copy, and one byte goes out. `done` works the
  same way in reverse: read STATUS0, remember bit 8, flip `go`, then poll until
  bit 8 differs. No pulse to miss, no shared writer, and it stays correct no
  matter how slow the polling is.

  ## RESETB defaults low

  `CTRL1` resets to zero, which holds the AD9363 in reset — deliberately. The
  transceiver comes up under our control rather than in whatever state the
  previous bitstream left it, and nothing can drive the shared LVDS bus until
  we say so. Elixir must raise RESETB before SPI will answer.

  ## LVDS receive front end — DDR capture in fabric, not ILOGIC

  `DATA_CLK` comes in through `IBUFDS` to a `BUFG`, giving a second clock domain
  sourced by the transceiver rather than the PS. `RX_FRAME` and the six data
  lanes are captured by **ordinary fabric flip-flops, two per lane** — one on
  `posedge data_clk`, one on `negedge` — giving twelve data bits per `DATA_CLK`,
  which is one sample word.

  ### Why not `IDDR`

  This used to use `Hw.Xilinx.IDDR`, which is the right primitive: dedicated
  ILOGIC registers beside the pad, with a characterised pad-to-register delay.
  It does not work under openXC7. Measured: Q1 constant 0 and Q2 constant 1 on
  all seven pairs, unchanged across a 2x `DATA_CLK` change and unchanged with the
  AD9363's data port forced to a static level — a DC input must give `Q1 == Q2`,
  so the ILOGIC flip-flops were not seeing the pad at all.

  The cause is in the database, not the design: prjxray characterises 2 of the 14
  ILOGICE3 site muxes for RIOI3, and the missing twelve include `IFFMUX`, `IMUX`,
  `D2OBYP_SEL` and `D2OFFBYP_SEL` — precisely the muxes that select what feeds
  the input flip-flops. nextpnr cannot emit bits that do not exist, so they take
  the all-zeros default. The ILOGIC *combinatorial* path works, which is how
  `DATA_CLK` gets in at all; only the flip-flop path is dead.

  Fabric flops cost a real thing: the fixed, characterised pad-to-register delay
  that makes source-synchronous timing closeable, and they put capture on the
  general routing fabric where skew between lanes is not guaranteed. That
  argument is why `Hw.Xilinx.IDDR`'s own moduledoc advises against exactly this.
  It was written for a fast bus. At a 16 MHz `DATA_CLK` with 4000 fabric cycles
  per OFDM symbol there is enormous margin, so the trade is worth taking — and
  unlike the alternative it needs no undocumented bits and no fuzzer.

  Restoring `IDDR` is still the right end state, and the fabric version makes
  that reachable: it is a known-good capture path to fuzz the ILOGIC muxes
  *against*, instead of trying to detect whether the IDDR works using the IDDR.

  ### Measuring DATA_CLK without a CDC hazard

  A free-running counter in the `DATA_CLK` domain cannot simply be sampled from
  the AXI domain: the bits change at different instants and a read that lands
  mid-increment tears, returning a value the counter never held. Rather than
  gray-code it, `DATA_CLK` is divided down to a single toggling bit, that one
  bit is crossed through a two-flop synchroniser, and the edges are counted on
  the AXI side. One bit crossing a domain has no tearing to worry about.

  So `STATUS2` counts `DATA_CLK / 512` periods. Read it twice a known interval
  apart and the transceiver's actual output frequency falls out — which is the
  only way to tell "the AD9363 is not configured to drive the bus yet" from
  "the bus is running and we are misreading it".

  ## Pins

  Every AD9363 signal is in bank 34, whose VCCO is 2.5 V (the transceiver's
  `VDD_INTERFACE` rail on this board). Single-ended control lines are therefore
  `LVCMOS25`, not 3.3 V — a bank has one VCCO, and the differential pairs in
  the same bank need 2.5 V for `LVDS_25`.
  """

  use Hw.Component

  # --- PS7 fabric clock / reset ---------------------------------------------
  wire :fclk_clk0, 1
  wire :fclk_reset0_n, 1
  wire :axi_clk, 1

  clock :axi_clk, freq: 100.0

  # 4 x the sample rate on a 2R2T LVDS bus, so ~16 MHz at a HaLow-appropriate
  # 4 MSPS. Constrained well above that; the point is headroom, not a target.
  # PS FCLK1: IO PLL 999.9 MHz / 5 = 200 MHz, already set by the FSBL, measured
  # at 199.97 MHz in the fabric. This is the IDELAYCTRL reference. Not a PL CMT
  # -- none of those lock under openXC7.
  clock :ref_clk, freq: 200.0

  clock :data_clk, freq: 60.0

  # The same physical net, declared again for falling-edge capture. `domain:`
  # ties it to `data_clk` so the analysis passes treat a transfer between the
  # two as source-synchronous rather than as a clock-domain crossing -- which it
  # is: the two edges are half a period apart on one clock, not two clocks.
  #
  # This replaces `IDDR`. See the "DDR capture in fabric" note below.
  clock :data_clk_b, freq: 60.0, edge: :negedge, domain: :data_clk

  # --- AD9363 control pins (bank 34, LVCMOS25) ------------------------------
  output :ad9363_spi_clk, 1
  output :ad9363_spi_di, 1
  input  :ad9363_spi_do, 1
  output :ad9363_spi_enb, 1
  output :ad9363_resetb, 1
  output :ad9363_enable, 1
  output :ad9363_txnrx, 1
  output :ad9363_en_agc, 1

  # AD9363 LVDS receive bus (bank 34, LVDS_25)
  input :ad9363_data_clk_p, 1
  input :ad9363_data_clk_n, 1
  input :ad9363_rx_frame_p, 1
  input :ad9363_rx_frame_n, 1
  input :ad9363_rx_d0_p, 1
  input :ad9363_rx_d0_n, 1
  input :ad9363_rx_d1_p, 1
  input :ad9363_rx_d1_n, 1
  input :ad9363_rx_d2_p, 1
  input :ad9363_rx_d2_n, 1
  input :ad9363_rx_d3_p, 1
  input :ad9363_rx_d3_n, 1
  input :ad9363_rx_d4_p, 1
  input :ad9363_rx_d4_n, 1
  input :ad9363_rx_d5_p, 1
  input :ad9363_rx_d5_n, 1

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

  wire :bid_q, 12, init: 0
  wire :rid_q, 12, init: 0
  wire :rlast_tie, 1

  wire :awaddr_low, 12
  wire :araddr_low, 12

  # --- register file <-> fabric ---------------------------------------------
  wire :ctrl0, 32
  wire :ctrl1, 32
  wire :ctrl2, 32
  wire :ctrl3, 32
  wire :status0, 32
  wire :status1, 32
  wire :status2, 32
  wire :status3, 32
  wire :zero32, 32

  # --- LVDS receive domain ---------------------------------------------------
  wire :data_clk_raw, 1
  wire :data_clk, 1

  wire :rx_frame_se, 1
  wire :rx_d0_se, 1
  wire :rx_d1_se, 1
  wire :rx_d2_se, 1
  wire :rx_d3_se, 1
  wire :rx_d4_se, 1
  wire :rx_d5_se, 1
  wire :zero, 1
  wire :one, 1

  # Each lane after its IDELAYE2. The tap is a bitstream constant, so a margin
  # sweep is one bitstream per tap -- see `IDELAY_TAP` below.
  wire :rx_d0_dly, 1
  wire :rx_d1_dly, 1
  wire :rx_d2_dly, 1
  wire :rx_d3_dly, 1
  wire :rx_d4_dly, 1
  wire :rx_d5_dly, 1
  wire :rx_frame_dly, 1

  # The six data lanes as one bus, single-ended out of the IBUFDS pads.
  wire :rx_bus_se, 6
  wire :data_clk_b, 1

  # Captured in fabric: rising-edge bits in one register, falling-edge bits in
  # another. Two flops per lane instead of one ILOGIC IDDR.
  wire :rise_q, 6, init: 0
  wire :fall_q, 6, init: 0
  wire :rise_frame_q, 1, init: 0
  wire :fall_frame_q, 1, init: 0

  # A 12-bit sample is {current 6 bits, previous 6 bits} FROM THE SAME EDGE, and
  # the two edges carry two different samples in parallel -- ADI's
  # axi_ad9361_lvds_if.v:
  #
  #     adc_data_p[23:12] <= {rx_data_1, rx_data_1_s};
  #     adc_data_p[11: 0] <= {rx_data_0, rx_data_0_s};
  #
  # `_s` is the same edge registered one DATA_CLK earlier, which is what these
  # two delay registers are. The previous version of this design built
  # `{fall_q, rise_q}` -- half of one sample glued to half of a different one.
  # It produced data with entirely plausible structure and no valid decoding.
  wire :rise_q_d, 6, init: 0
  wire :fall_q_d, 6, init: 0

  wire :sample_a, 12, init: 0
  wire :sample_b, 12, init: 0
  wire :frame_pair, 2, init: 0

  # --- snapshot capture buffer ------------------------------------------------
  #
  # 1024 consecutive sample words, written at full DATA_CLK rate and read out
  # slowly over AXI once capture has halted.
  #
  # This replaces reading the live `sample_word` through `status3`, which was an
  # unsynchronised crossing: a 12-bit register in the DATA_CLK domain wired
  # combinationally into the AXI read path. Individual bits could be captured
  # either side of a transition, and successive reads were thousands of DATA_CLK
  # periods apart at unrelated phase — so they were never consecutive samples.
  # Anything needing sample *order* (a PRBS check, the RX_FRAME waveform, any
  # DSP) was impossible, and the statistics that were possible could not
  # distinguish a torn word from a real one.
  #
  # The write port is clocked by DATA_CLK and the read port by AXI_CLK
  # (`sync_read: :axi_clk`), which is a true dual-port BRAM. That is safe here
  # for a specific reason worth stating: readout only happens after capture has
  # halted, so the write port is idle and the memory contents are static. This is
  # the "snapshot before DMA" call from the handoff — no bursts, no DMA, and no
  # coherency argument to get wrong.
  # Depth 4096, and the number is load-bearing.
  #
  # Yosys emits a per-bit write enable for this array (`_EN[25:0]` in the log).
  # Once the array no longer fits one RAMB36 it is cascaded in depth, and every
  # BRAM in the cascade needs its own address-decoded enable for every bit. That
  # decode is where the inverters come from, and it scales with depth x width:
  #
  #     1024 x 26  ->  1 RAMB36,    1 INV     (routed, seed 25)
  #     8192 x 26  ->  6 RAMB36,  120 INV     (0 of 242 seeds routed)
  #     8192 x 28  ->  7 RAMB36,  185 INV     (worse -- padding does not help)
  #
  # Widening to a "native" RAMB geometry was tried and made it worse, because the
  # cost is in the depth cascade, not the width tiling.
  #
  # 4096 keeps the cascade shallow while still being the depth that matters:
  # 4096 words is 1024 samples per channel, and at the 1 Msps HaLow target that
  # is 1.02 ms -- long enough for a beacon, which is the whole point. At 8 Msps
  # it is 128 us.
  # Banked by hand into four single-BRAM arrays, NOT one 4096-deep array.
  #
  # Yosys emits a per-bit write enable (`_EN[25:0]`). While the array fits one
  # RAMB36 that is a single signal; the moment it does not, yosys cascades in
  # depth and every BRAM in the cascade needs its own address-decoded enable for
  # every bit. That decode is ~120 INV cells, and it is unroutable here: 755
  # seeds failed across 8192x26, 8192x28 and 4096x26, every one of them in SLICE
  # set/reset muxing. The 1024-deep version has exactly 1 INV and routes.
  #
  # Four explicit 1024-deep arrays keep each one inside a single BRAM with a
  # trivial enable, and pay instead for a 2-bit write decode and a 4:1 read mux
  # -- about 52 LUT6, against 120 inverters.
  memory :cap0, width: 26, depth: 1024, sync_read: :axi_clk
  memory :cap1, width: 26, depth: 1024, sync_read: :axi_clk
  memory :cap2, width: 26, depth: 1024, sync_read: :axi_clk
  memory :cap3, width: 26, depth: 1024, sync_read: :axi_clk
  memory :cap4, width: 26, depth: 1024, sync_read: :axi_clk
  memory :cap5, width: 26, depth: 1024, sync_read: :axi_clk
  memory :cap6, width: 26, depth: 1024, sync_read: :axi_clk
  memory :cap7, width: 26, depth: 1024, sync_read: :axi_clk

  wire :cap_sample, 26
  wire :cap_wr_bank, 3
  wire :cap_wr_idx, 10
  wire :cap_rd_bank, 3
  wire :cap_rd_idx, 10
  wire :cap_w4, 26
  wire :cap_w5, 26
  wire :cap_w6, 26
  wire :cap_w7, 26
  wire :cap_w0, 26
  wire :cap_w1, 26
  wire :cap_w2, 26
  wire :cap_w3, 26
  wire :cap_arm_bit, 1
  wire :cap_arm_sync, 1
  wire :cap_arm_prev, 1, init: 0
  wire :cap_wr_addr, 13, init: 0
  wire :cap_running, 1, init: 0
  wire :cap_done, 1, init: 0
  wire :cap_done_sync, 1
  wire :cap_rd_addr, 13
  wire :cap_rd_ptr, 13, init: 0
  wire :status3_rd, 1
  wire :ctrl2_wr, 1
  wire :cap_word, 26, init: 0
  wire :pad5, 5

  # DATA_CLK / 512, crossed as a single bit.
  wire :dclk_div, 9, init: 0
  wire :dclk_tick, 1
  wire :dclk_tick_sync, 1
  wire :dclk_tick_prev, 1, init: 0
  wire :dclk_count, 24, init: 0
  wire :axi_rst, 1

  wire :heartbeat, 24, init: 0

  # --- SPI plumbing ----------------------------------------------------------
  wire :spi_rst, 1
  wire :spi_tx_data, 8
  wire :spi_cs_hold, 1
  wire :spi_tx_valid, 1
  wire :spi_tx_ready, 1
  wire :spi_rx_data, 8
  wire :spi_rx_valid, 1

  wire :go_bit, 1
  wire :go_shadow, 1, init: 0
  wire :req_pending, 1, init: 0
  wire :rx_data_reg, 8, init: 0
  wire :done_toggle, 1, init: 0

  # Explicit zero fields for the status word concatenations. A sized literal
  # inside a concat (`{0::22, ...}`) is not parsed by the DSL, so the padding
  # is a named wire.
  wire :pad22, 22
  wire :pad8, 8
  wire :pad7, 7
  wire :pad2, 2

  # Runtime tap control. CTRL1[12:8] is the tap, CTRL1[13] is LD.
  #
  # LD is used LEVEL-sensitively rather than as a pulse: IDELAYE2 reloads
  # CNTVALUEIN on every rising C edge while LD is high, so holding it high
  # simply reloads the same value and there is no edge-detect logic to get
  # wrong. Software writes {tap, LD=1} then {tap, LD=0}.
  wire :tap_value, 5
  wire :tap_ld, 1

  # CNTVALUEOUT per lane. Only lane 0 is exposed -- all seven are loaded from
  # the same CTRL1 field, so one readback proves the load path for all of them.
  wire :cnt0, 5
  wire :cnt1, 5
  wire :cnt2, 5
  wire :cnt3, 5
  wire :cnt4, 5
  wire :cnt5, 5
  wire :cnt6, 5
  wire :fclk_clk1, 1
  wire :ref_clk, 1
  wire :idelayctrl_rst, 1
  wire :idelayctrl_rdy, 1
  wire :idelayctrl_rdy_sync, 1

  # --- HP0 DMA streaming path (Gate 3 of nervezynq/AXI_PLAN.md) ---------------
  #
  # PL-mastered writes into a DDR ring over S_AXI_HP0, controlled and observed
  # entirely over EMIO GPIO — a deliberate zero dependence on the GP0 slave
  # path, kept even now that GP0 is proven alive (the 2026-08-02 THR_CNT
  # find): the stream must survive any future GP fault, and EMIO already
  # proved itself as the fallback instrument. Two producers feed the ring
  # through one FIFO+engine path, selected by EMIO bit 1: the original
  # 64-bit pattern counter (the +1 continuity oracle from the first-silicon
  # session, retained as the permanent transport regression gate) and the
  # LVDS radio stream via Hw.AD936xFramePacker (one self-framing 64-bit
  # word per radio frame — see the packer wire block below).
  #
  # Ring: the TOP 1 MB of the existing, proven 4 MB DmaBuf reservation
  # (0x3FC0_0000 + 3 MB = 0x3FF0_0000). Deliberately inside a region the
  # kernel already keeps away from Linux, so the first HP0 silicon session
  # needs no device-tree change and no firmware burn. The cost is a sharing
  # rule: DmaBuf allocations (devcfg readback buffers, a few tens of KB)
  # must stay below the 3 MB mark while DMA tests run — do not run a
  # readback census concurrently with a DMA soak. Both constants are baked:
  # with GP dead there is no register path to configure them, and EMIO has
  # nowhere near 64 spare bits. Power-of-two ring, base aligned, per
  # Hw.AXIHPWriter's ring discipline.
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
  wire :hp_wacount, 6
  wire :hp_wcount, 8

  wire :emio_in, 64
  wire :emio_out, 64

  wire :dma_enable, 1
  wire :dma_base, 32
  wire :dma_ring, 32
  wire :dma_write_ptr, 32
  wire :dma_bursts, 16
  wire :dma_bresp_errs, 8
  wire :dma_s_avail, 1
  wire :wptr_lo, 16
  wire :hb_bit, 1
  wire :alive_bit, 1

  # The self-checking payload, in exactly the halved form the original
  # comment promised if routing ever complained (it did — the wire block's
  # history is in Hw.StreamBRAMFIFO's moduledoc): a 32-bit counter packed
  # as {~ctr, ctr}. The complement makes the high half self-checking and
  # keeps every 64-bit word unique through the full 32-bit period.
  wire :pat_lo, 32, init: 0
  wire :pat_inv, 32
  wire :pat_word, 64

  # --- radio stream: packer -> dual-clock BRAM FIFO -> HP0 -------------------
  #
  # The packer walks the RX_FRAME cycle in the DATA_CLK domain and emits one
  # self-framing 64-bit word per radio frame (I1/Q1/I2/Q2 + SEQ + ERR — the
  # format is Hw.AD936xFramePacker's moduledoc, mirrored in
  # Nervezynq.SampleFormat / hp_stream.exs).
  #
  # The clock-domain crossing is Hw.StreamBRAMFIFO: words enter on DATA_CLK
  # through one BRAM port and leave on AXI_CLK through the other — the same
  # silicon-proven crossing the capture banks use, with an 11-bit gray write
  # pointer as the ONLY fabric-level crossing. The earlier toggle-CDC +
  # register-FIFO revision, though simulable and correct, was unroutable:
  # 0/167 seeds, all on clock leaves, because its 64 cross-domain data wires
  # interleaved the two clock islands tile-by-tile (see Hw.StreamBRAMFIFO's
  # moduledoc for the measured wire counts).
  #
  # BOTH producers now live in the DATA_CLK domain and feed the same BRAM
  # write port, so the +1 continuity oracle exercises the identical
  # FIFO+engine+ring path as radio words. The trade recorded honestly:
  # counter mode now needs DATA_CLK alive (AD9363 configured), where the V0
  # counter ran clockless off AXI. SDR.open/1 is the ritual either way.
  #
  # EMIO bit 1 selects the producer (0 = counter at DATA_CLK/4 — the radio
  # word rate — 1 = radio packer). EMIO bit 2 clears the sticky flags.
  wire :pk_enable_axi, 1
  wire :pk_enable, 1
  wire :pk_word, 64
  wire :pk_toggle, 1
  wire :pk_tog_d, 1, init: 0
  wire :pk_sync_lost, 1
  wire :pk_sync_lost_sync, 1
  wire :src_sel, 1
  wire :src_sel_dclk, 1
  wire :stat_clear, 1
  wire :en_dclk, 1
  wire :ctr_div, 2, init: 0
  wire :ctr_full, 1
  wire :sf_wr_en, 1
  wire :sf_wr_radio, 1
  wire :sf_wr_ctr, 1
  wire :sf_wr_data, 64
  wire :sf_rd_rst, 1
  wire :sf_count, 11
  wire :sf_over, 1
  wire :ov_prev, 1, init: 0
  wire :fifo_rd_en, 1
  wire :fifo_rd_data, 64
  wire :overrun_sticky, 1, init: 0
  wire :overrun_ctr, 3, init: 0

  # Inlined Hw.StreamBRAMFIFO state (see the instance-site comment for why
  # it is inlined). Storage: 1024 x 64, one array — two RAMB36 side by
  # side, no depth cascade, so none of the address-decode INV plague.
  memory :sbuf, width: 64, depth: 1024, sync_read: :axi_clk

  wire :sb_wr_ptr, 11, init: 0
  wire :sb_wr_gray, 11, init: 0
  wire :sb_wptr_next, 11
  wire :sb_wr_idx, 10
  wire :sb_wg_x, 11
  wire :sb_wg_s0, 11, init: 0
  wire :sb_wg_s1, 11, init: 0
  wire :sb_gb1, 11
  wire :sb_gb2, 11
  wire :sb_gb4, 11
  wire :sb_wr_bin, 11
  wire :sb_rd_ptr, 11, init: 0
  wire :sb_rd_idx, 10

  instance :ps, Hw.PS7HP,
    fclk_clk0: :fclk_clk0,
    fclk_clk1: :fclk_clk1,
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
    maxigp0_rid: :rid_q,
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
    saxihp0_wacount: :hp_wacount,
    saxihp0_wcount: :hp_wcount,
    emio_gpio_i: :emio_in,
    emio_gpio_o: :emio_out

  # PIPELINED_SOURCE matches the BRAM FIFO's strobed read port: s_ren
  # advances the read pointer and the word arrives one cycle later, so the
  # engine spaces beats two cycles apart (~400 MB/s ceiling, ~6x the radio
  # worst case). The 1024-deep FIFO makes burst-availability trivial:
  # s_avail gates on count >= 16 with three orders of magnitude of headroom
  # against the producer's ≤ DATA_CLK/4 word rate.
  instance :dma, Hw.AXIHPWriter,
    BURST_LEN: 16,
    PIPELINED_SOURCE: 1,
    aclk: :axi_clk,
    aresetn: :fclk_reset0_n,
    s_data: :fifo_rd_data,
    s_avail: :dma_s_avail,
    s_ren: :fifo_rd_en,
    base_addr: :dma_base,
    ring_size: :dma_ring,
    enable: :dma_enable,
    write_ptr: :dma_write_ptr,
    bursts: :dma_bursts,
    bresp_errs: :dma_bresp_errs,
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

  instance :packer, Hw.AD936xFramePacker,
    clk: :data_clk,
    enable: :pk_enable,
    sample_a: :sample_a,
    sample_b: :sample_b,
    frame_pair: :frame_pair,
    word: :pk_word,
    word_toggle: :pk_toggle,
    sync_lost: :pk_sync_lost

  # Control bits into the DATA_CLK domain: same no-reset rule as the rest
  # of that domain (rst: :zero, like cap_arm_cdc).
  instance :pk_en_cdc, Hw.CDC.Sync2,
    clk_dst: :data_clk, rst: :zero, data_in: :pk_enable_axi, data_out: :pk_enable

  instance :src_sel_cdc, Hw.CDC.Sync2,
    clk_dst: :data_clk, rst: :zero, data_in: :src_sel, data_out: :src_sel_dclk

  instance :en_dclk_cdc, Hw.CDC.Sync2,
    clk_dst: :data_clk, rst: :zero, data_in: :dma_enable, data_out: :en_dclk

  instance :pk_lost_cdc, Hw.CDC.Sync2,
    clk_dst: :axi_clk, rst: :axi_rst, data_in: :pk_sync_lost, data_out: :pk_sync_lost_sync

  # The domain crossing itself — Hw.StreamBRAMFIFO's logic INLINED here
  # rather than instantiated: the elaborator cannot resolve a component-
  # local `sync_read:` clock (ElabError: "no clock named :rd_clk exists",
  # 2026-08-03 — the capture banks never hit this because every sync_read
  # memory in the project lives at top level). Filed alongside the
  # MemWrite simulator item; when instance-local sync_read lands, this
  # collapses back into the component. The logic below is line-for-line
  # Hw.StreamBRAMFIFO — keep them in step.

  instance :refbuf, Hw.Xilinx.BUFG,
    i: :fclk_clk1, o: :ref_clk

  # One instance covers all seven lanes: nextpnr duplicates the cell into every
  # bank holding a member of its IODELAY_GROUP.
  instance :idelayctrl, Hw.Xilinx.IDELAYCTRL,
    refclk: :ref_clk, rst: :idelayctrl_rst, rdy: :idelayctrl_rdy

  # RDY is asynchronous to the AXI clock.
  instance :idelayctrl_rdy_cdc, Hw.CDC.Sync2,
    clk_dst: :axi_clk, rst: :axi_rst, data_in: :idelayctrl_rdy,
    data_out: :idelayctrl_rdy_sync

  instance :clkbuf, Hw.Xilinx.BUFG,
    i: :fclk_clk0,
    o: :axi_clk

  instance :axil, Hw.AXI4Lite.Slave,
    status3_rd: :status3_rd,
    ctrl2_wr: :ctrl2_wr,
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
    ctrl0: :ctrl0,
    ctrl1: :ctrl1,
    ctrl2: :ctrl2,
    ctrl3: :ctrl3,
    status0: :status0,
    status1: :status1,
    status2: :status2,
    status3: :status3

  # 1 MHz SCK off a 100 MHz fabric clock. The AD9363 will take far more, but
  # nothing here is rate limited by SPI: a full init is a few hundred registers
  # and the whole point of this stage is to find out whether the wires are
  # right, not how fast they can be wrong.
  instance :spi, Hw.SPI.Master,
    # The AD936x drives SPI_DO on the RISING edge of SCLK, so MISO must be
    # sampled half a period later than the master's default. Without this every
    # byte read back is shifted one bit and its LSB is lost.
    MISO_SAMPLE_TRAILING: 1,
    CLK_FREQ: 100_000_000,
    SCK_FREQ: 1_000_000,
    clk: :axi_clk,
    rst: :spi_rst,
    tx_data: :spi_tx_data,
    tx_valid: :spi_tx_valid,
    cs_hold: :spi_cs_hold,
    tx_ready: :spi_tx_ready,
    rx_data: :spi_rx_data,
    rx_valid: :spi_rx_valid,
    sck: :ad9363_spi_clk,
    mosi: :ad9363_spi_di,
    miso: :ad9363_spi_do,
    cs_n: :ad9363_spi_enb

  instance :dclk_ibufds, Hw.Xilinx.IBUFDS,
    i: :ad9363_data_clk_p, ib: :ad9363_data_clk_n, o: :data_clk_raw

  instance :dclk_bufg, Hw.Xilinx.BUFG,
    i: :data_clk_raw, o: :data_clk

  instance :frame_ibufds, Hw.Xilinx.IBUFDS,
    i: :ad9363_rx_frame_p, ib: :ad9363_rx_frame_n, o: :rx_frame_se

  instance :d0_ibufds, Hw.Xilinx.IBUFDS,
    i: :ad9363_rx_d0_p, ib: :ad9363_rx_d0_n, o: :rx_d0_se
  instance :d1_ibufds, Hw.Xilinx.IBUFDS,
    i: :ad9363_rx_d1_p, ib: :ad9363_rx_d1_n, o: :rx_d1_se
  instance :d2_ibufds, Hw.Xilinx.IBUFDS,
    i: :ad9363_rx_d2_p, ib: :ad9363_rx_d2_n, o: :rx_d2_se
  instance :d3_ibufds, Hw.Xilinx.IBUFDS,
    i: :ad9363_rx_d3_p, ib: :ad9363_rx_d3_n, o: :rx_d3_se
  instance :d4_ibufds, Hw.Xilinx.IBUFDS,
    i: :ad9363_rx_d4_p, ib: :ad9363_rx_d4_n, o: :rx_d4_se
  instance :d5_ibufds, Hw.Xilinx.IBUFDS,
    i: :ad9363_rx_d5_p, ib: :ad9363_rx_d5_n, o: :rx_d5_se

  # --- input delay line ---------------------------------------------------
  #
  # One IDELAYE2 per receive lane, including RX_FRAME: delaying the data and
  # not the framing signal would shear the two apart and the frame-phase
  # rotation in `Nervezynq.MIMO` would stop matching.
  #
  # DATA_CLK is deliberately NOT delayed. The tap moves the data relative to
  # the sampling clock; moving both moves nothing.
  #
  # @idelay_tap is the whole experiment. Sweep it 0..31 across bitstreams and
  # decode at each one; the taps that still decode are the eye.
  instance :d0_idelay, Hw.Xilinx.IDELAYE2,
    idatain: :rx_d0_se, dataout: :rx_d0_dly,
    c: :axi_clk, ld: :tap_ld, ce: :zero, inc: :zero,
    cntvaluein: :tap_value, cntvalueout: :cnt0,
    IDELAY_TYPE: "VAR_LOAD", IDELAY_VALUE: @idelay_tap
  instance :d1_idelay, Hw.Xilinx.IDELAYE2,
    idatain: :rx_d1_se, dataout: :rx_d1_dly,
    c: :axi_clk, ld: :tap_ld, ce: :zero, inc: :zero,
    cntvaluein: :tap_value, cntvalueout: :cnt1,
    IDELAY_TYPE: "VAR_LOAD", IDELAY_VALUE: @idelay_tap
  instance :d2_idelay, Hw.Xilinx.IDELAYE2,
    idatain: :rx_d2_se, dataout: :rx_d2_dly,
    c: :axi_clk, ld: :tap_ld, ce: :zero, inc: :zero,
    cntvaluein: :tap_value, cntvalueout: :cnt2,
    IDELAY_TYPE: "VAR_LOAD", IDELAY_VALUE: @idelay_tap
  instance :d3_idelay, Hw.Xilinx.IDELAYE2,
    idatain: :rx_d3_se, dataout: :rx_d3_dly,
    c: :axi_clk, ld: :tap_ld, ce: :zero, inc: :zero,
    cntvaluein: :tap_value, cntvalueout: :cnt3,
    IDELAY_TYPE: "VAR_LOAD", IDELAY_VALUE: @idelay_tap
  instance :d4_idelay, Hw.Xilinx.IDELAYE2,
    idatain: :rx_d4_se, dataout: :rx_d4_dly,
    c: :axi_clk, ld: :tap_ld, ce: :zero, inc: :zero,
    cntvaluein: :tap_value, cntvalueout: :cnt4,
    IDELAY_TYPE: "VAR_LOAD", IDELAY_VALUE: @idelay_tap
  instance :d5_idelay, Hw.Xilinx.IDELAYE2,
    idatain: :rx_d5_se, dataout: :rx_d5_dly,
    c: :axi_clk, ld: :tap_ld, ce: :zero, inc: :zero,
    cntvaluein: :tap_value, cntvalueout: :cnt5,
    IDELAY_TYPE: "VAR_LOAD", IDELAY_VALUE: @idelay_tap
  instance :frame_idelay, Hw.Xilinx.IDELAYE2,
    idatain: :rx_frame_se, dataout: :rx_frame_dly,
    c: :axi_clk, ld: :tap_ld, ce: :zero, inc: :zero,
    cntvaluein: :tap_value, cntvalueout: :cnt6,
    IDELAY_TYPE: "VAR_LOAD", IDELAY_VALUE: @idelay_tap


  instance :dclk_sync, Hw.CDC.Sync2,
    clk_dst: :axi_clk, rst: :axi_rst, data_in: :dclk_tick, data_out: :dclk_tick_sync

  # The arm signal crosses as a TOGGLE, not a pulse — an AXI register holds its
  # value and has no write-pulse semantics, exactly as for the SPI `go` bit. One
  # bit crossing a domain has no tearing to worry about.
  instance :cap_arm_cdc, Hw.CDC.Sync2,
    clk_dst: :data_clk, rst: :zero, data_in: :cap_arm_bit, data_out: :cap_arm_sync

  instance :cap_done_cdc, Hw.CDC.Sync2,
    clk_dst: :axi_clk, rst: :axi_rst, data_in: :cap_done, data_out: :cap_done_sync

  comb do
    zero32 = 0
    zero = 0
    one = 1
    rlast_tie = 1
    axi_rst = not fclk_reset0_n

    rx_bus_se = {rx_d5_dly, rx_d4_dly, rx_d3_dly, rx_d2_dly, rx_d1_dly, rx_d0_dly}

    # Same net, second name. yosys collapses the buffer; what survives is a set
    # of negedge flops, which map onto the CLB flop's own clock-inversion bit.
    data_clk_b = data_clk

    dclk_tick = dclk_div[8..8]

    # Two complete 12-bit samples plus the frame pair. Nothing live is exposed
    # directly — see the capture buffer note above.
    cap_sample = {frame_pair, sample_b, sample_a}
    cap_arm_bit = ctrl2[16..16]
    # The read pointer AUTO-ADVANCES on every completed STATUS3 read, so N
    # words cost one userspace round trip instead of N. Writing CTRL2 still
    # loads it, so "seek then read" still works -- it just no longer has to
    # seek before every single word.
    #
    # Measured motivation: a bus read is ~1.06 us, a userspace round trip is
    # ~215 us. Removing the per-word round trip is a ~200x readout speedup and
    # is what makes a whole beacon readable.
    cap_rd_addr = cap_rd_ptr
    cap_rd_bank = cap_rd_addr[12..10]
    cap_rd_idx = cap_rd_addr[9..0]
    cap_w0 = cap0[cap_rd_idx]
    cap_w1 = cap1[cap_rd_idx]
    cap_w2 = cap2[cap_rd_idx]
    cap_w3 = cap3[cap_rd_idx]
    cap_w4 = cap4[cap_rd_idx]
    cap_w5 = cap5[cap_rd_idx]
    cap_w6 = cap6[cap_rd_idx]
    cap_w7 = cap7[cap_rd_idx]

    cap_wr_bank = cap_wr_addr[12..10]
    cap_wr_idx = cap_wr_addr[9..0]
    pad5 = 0

    status2 = {pad8, dclk_count}

    # 5 + 1 + 26 = 32.
    status3 = {pad5, cap_done_sync, cap_word}
    awaddr_low = awaddr[11..0]
    araddr_low = araddr[11..0]

    spi_rst = not fclk_reset0_n

    spi_tx_data = ctrl0[7..0]
    spi_cs_hold = ctrl0[8..8]
    go_bit = ctrl0[9..9]

    # Held until the master accepts it, rather than a single-cycle pulse that
    # would be dropped if the master happened to be busy.
    spi_tx_valid = req_pending

    ad9363_resetb = ctrl1[0..0]
    ad9363_enable = ctrl1[1..1]
    ad9363_txnrx  = ctrl1[2..2]
    ad9363_en_agc = ctrl1[3..3]

    # CTRL1[4]. Software-controlled so that "tie RST low" and "pulse RST" can
    # both be tested without rebuilding. CTRL1 resets to zero, so RST starts
    # DEASSERTED and end-of-configuration GSR is the only reset unless software
    # asks for another.
    idelayctrl_rst = ctrl1[4..4]
    tap_value = ctrl1[12..8]
    tap_ld = ctrl1[13..13]

    pad22 = 0
    pad8 = 0
    pad7 = 0
    pad2 = 0
    status0 = {pad22, spi_tx_ready, done_toggle, rx_data_reg}
    # [23:0] heartbeat, [24] IDELAYCTRL RDY, [29:25] lane-0 CNTVALUEOUT.
    # CNTVALUEOUT is the point of VAR_LOAD: it reports the tap the silicon is
    # actually using, so "the tap took effect" becomes a measurement rather
    # than a belief about which bitstream got loaded.
    status1 = {pad2, cnt0, idelayctrl_rdy_sync, heartbeat}

    # --- HP0 DMA: constants, control, and the EMIO status word ---------------
    # Top 1 MB of the DmaBuf reservation — see the wire-block comment.
    dma_base = 0x3FF00000
    dma_ring = 0x00100000

    # EMIO bank 2 control bits (Linux gpiochip lines 54+). Until software
    # configures the bank direction and drives it, EMIOGPIOO reads 0 — the
    # engine wakes up disabled with the counter producer selected, which is
    # the safe default on a board where nothing has reserved the ring yet.
    #   [0] dma_enable   [1] producer select (0 counter / 1 radio)
    #   [2] clear sticky overrun/sync flags (level)
    dma_enable = emio_out[0..0]
    src_sel = emio_out[1..1]
    stat_clear = emio_out[2..2]

    # The packer only runs when the stream is enabled AND selected; SEQ
    # restarts from 0 on every enable, so a stream begins self-labelled.
    pk_enable_axi = band(dma_enable, src_sel)

    # Disabled flushes the read side to empty (rd_ptr snaps to the synced
    # write pointer): every stream start begins empty, and a producer
    # switch never replays stale words from the other producer.
    sf_rd_rst = bor(axi_rst, bnot(dma_enable))

    # A full burst must be resident before the engine commits (s_avail is
    # only sampled in :idle, and AXI cannot pause a write burst mid-flight).
    dma_s_avail = sf_count >= 16

    # count > 1024 means the producer lapped the unread region since the
    # last flush — real data loss, latched sticky below.
    sf_over = sf_count >= 1025

    # Producer plumbing, all DATA_CLK domain. The packer flips word_toggle
    # on emit; one delayed copy turns that into a write strobe the cycle
    # AFTER pk_word settles. The counter writes every 4th DATA_CLK — the
    # radio word rate — so the +1 oracle loads the path identically.
    ctr_full = ctr_div == 3
    sf_wr_radio = band(bxor(pk_toggle, pk_tog_d), src_sel_dclk)
    sf_wr_ctr = band(band(en_dclk, bnot(src_sel_dclk)), ctr_full)
    sf_wr_en = bor(sf_wr_radio, sf_wr_ctr)

    pat_inv = bnot(pat_lo)
    pat_word = {pat_inv, pat_lo}
    sf_wr_data = pat_word

    hdl_case <<src_sel_dclk::1>> do
      <<0::1>> -> sf_wr_data = pat_word
      <<1::1>> -> sf_wr_data = pk_word
    end

    # Inlined StreamBRAMFIFO combinational half: gray->binary prefix XOR
    # over the synchronised write pointer, the conservative fill count,
    # and the sync-read head.
    sb_wptr_next = sb_wr_ptr + 1
    sb_wr_idx = sb_wr_ptr[9..0]
    sb_rd_idx = sb_rd_ptr[9..0]
    # Comb alias for the gray pointer crossing. The crossing itself is safe
    # by construction — gray code, one bit changes per increment, per-bit
    # 2-flop sync below — but the validator's hard CDC check models only
    # direct reg->reg reads (its whitelist set has no writer today), so this
    # gives the crossing the same comb-fed shape every Hw.CDC.Sync2 use in
    # this design already has. Do NOT read sb_wg_x anywhere else.
    sb_wg_x = sb_wr_gray

    sb_gb1 = bxor(sb_wg_s1, sb_wg_s1 >>> 1)
    sb_gb2 = bxor(sb_gb1, sb_gb1 >>> 2)
    sb_gb4 = bxor(sb_gb2, sb_gb2 >>> 4)
    sb_wr_bin = bxor(sb_gb4, sb_gb4 >>> 8)
    sf_count = sb_wr_bin - sb_rd_ptr
    fifo_rd_data = sbuf[sb_rd_idx]

    hb_bit = heartbeat[23..23]
    alive_bit = fclk_reset0_n
    wptr_lo = dma_write_ptr[19..4]

    # EMIO status word, read from Linux as GPIO inputs (lines 54..117).
    #   [15:0]  bursts        [31:16] write_ptr[19:4]   [39:32] bresp_errs
    #   [40] heartbeat[23]    [41] alive (must read 1)  [42] must read 1
    #   [43] must read 0      [49:44] HP0 WACOUNT       [57:50] HP0 WCOUNT
    #   [60:58] FIFO overrun count   [61] overrun sticky
    #   [62] packer sync_lost sticky [63] producer select readback
    # Bits 41..43 are the EMIO smoke test: they prove the read path before
    # any DMA conclusion is drawn from the other fields. WACOUNT/WCOUNT vs
    # bursts is the "PL never issued / PS absorbed / stuck mid-burst" triage.
    emio_in = {src_sel, pk_sync_lost_sync, overrun_sticky, overrun_ctr,
               hp_wcount, hp_wacount, zero, one, alive_bit, hb_bit,
               dma_bresp_errs, wptr_lo, dma_bursts}
  end

  # --- DATA_CLK domain -------------------------------------------------------
  #
  # No reset: FCLK_RESET0_N belongs to the PS clock, and this domain may have no
  # clock at all until the AD9363 is configured to drive DATA_CLK. Everything
  # here starts from its init value and is only ever read through the
  # synchroniser, so there is nothing for a reset to rescue.
  on :data_clk do
    dclk_div = dclk_div + 1

    rise_q = rx_bus_se
    rise_frame_q = rx_frame_dly

    # Every read in this block sees the PREVIOUS value -- nonblocking semantics.
    # So `rise_q` here is the bit captured at the last posedge and `rise_q_d`
    # the one before it.
    rise_q_d = rise_q

    # {previous, current} -- the OLDER six bits are the MSBs. The AD9363 sends
    # the MSB nibble first, so at the cycle a word completes the current six bits
    # are its LSBs. This matches ADI's axi_ad9361_lvds_if.v:
    #
    #     adc_data_p[23:12] <= {rx_data_1, rx_data_1_s};
    #
    # where rx_data_1 is the registered (previous) cycle and rx_data_1_s the
    # combinational (current) one. This was the other way round until it was
    # measured: under the Fs/32 BIST tone, mag_cv is 3.4e-4 in this order against
    # 0.376 reversed.
    sample_a = {rise_q_d, rise_q}
    sample_b = {fall_q_d, fall_q}

    # No delay stage here, deliberately. `frame_pair` is contemporaneous with the
    # newest half of the sample word, and measurement says that is correct: frame
    # integrity is 1.0 across a full capture and both channels decode to exactly
    # +11.25 deg/sample. Adding a `_d` to match the data lanes would shift the
    # phase and invalidate the [3,1,0,2] cycle constant alignment depends on.
    frame_pair = {fall_frame_q, rise_frame_q}

    # A sample completes every two DATA_CLK cycles, so only alternate cycles
    # carry a correctly-aligned pair; the other parity straddles two samples.
    # Both are still written and the parity chosen at readout -- but it is no
    # longer a guess: RX_FRAME in pulse mode (0x010 bit 3) marks the frame, and
    # Nervezynq.MIMO rotates on it. Exactly four of the eight slots per frame
    # carry signal, and they are the ones this parity selects.

    # Capture: edge-detect the armed toggle, then write consecutive samples until
    # the buffer is full and stop. Stopping matters — a wrapping buffer would be
    # readable only while it was being overwritten, which is the problem this
    # exists to solve.
    cap_arm_prev = cap_arm_sync

    if bxor(cap_arm_sync, cap_arm_prev) == 1 do
      cap_running = 1
      cap_done = 0
      cap_wr_addr = 0
    else
      if cap_running == 1 do
        if cap_wr_bank == 0 do
          cap0[cap_wr_idx] = cap_sample
        end

        if cap_wr_bank == 1 do
          cap1[cap_wr_idx] = cap_sample
        end

        if cap_wr_bank == 2 do
          cap2[cap_wr_idx] = cap_sample
        end

        if cap_wr_bank == 3 do
          cap3[cap_wr_idx] = cap_sample
        end

        if cap_wr_bank == 4 do
          cap4[cap_wr_idx] = cap_sample
        end

        if cap_wr_bank == 5 do
          cap5[cap_wr_idx] = cap_sample
        end

        if cap_wr_bank == 6 do
          cap6[cap_wr_idx] = cap_sample
        end

        if cap_wr_bank == 7 do
          cap7[cap_wr_idx] = cap_sample
        end

        if cap_wr_addr == 8191 do
          cap_running = 0
          cap_done = 1
        else
          cap_wr_addr = cap_wr_addr + 1
        end
      end
    end
  end

  # Falling-edge half of the DDR capture.
  on :data_clk_b do
    fall_q = rx_bus_se
    fall_frame_q = rx_frame_dly
    fall_q_d = fall_q
  end

  on :axi_clk do
    if fclk_reset0_n == 0 do
      heartbeat = 0
    else
      heartbeat = heartbeat + 1

      # Load beats advance. A seek arriving in the same cycle as a read should
      # land where the seek asked, not one past it.
      if status3_rd == 1 do
        cap_rd_ptr = cap_rd_ptr + 1
      end

      if ctrl2_wr == 1 do
        cap_rd_ptr = ctrl2[12..0]
      end
    end

    # 4:1 readout mux, registered. One extra cycle of latency is free: the host
    # writes the address to ctrl2 and reads status3 in a separate AXI
    # transaction, many cycles later.
    if cap_rd_bank == 0 do
      cap_word = cap_w0
    end

    if cap_rd_bank == 1 do
      cap_word = cap_w1
    end

    if cap_rd_bank == 2 do
      cap_word = cap_w2
    end

    if cap_rd_bank == 3 do
      cap_word = cap_w3
    end

    if cap_rd_bank == 4 do
      cap_word = cap_w4
    end

    if cap_rd_bank == 5 do
      cap_word = cap_w5
    end

    if cap_rd_bank == 6 do
      cap_word = cap_w6
    end

    if cap_rd_bank == 7 do
      cap_word = cap_w7
    end
  end

  # Count DATA_CLK/512 edges after the single-bit crossing.
  on :axi_clk do
    if fclk_reset0_n == 0 do
      dclk_tick_prev = 0
      dclk_count = 0
    else
      dclk_tick_prev = dclk_tick_sync

      if dclk_tick_sync == 1 and dclk_tick_prev == 0 do
        dclk_count = dclk_count + 1
      end
    end
  end

  # Edge-detect the go toggle, hold the request until the master takes it.
  on :axi_clk do
    if fclk_reset0_n == 0 do
      go_shadow = 0
      req_pending = 0
    else
      if bxor(go_bit, go_shadow) == 1 do
        go_shadow = go_bit
        req_pending = 1
      else
        if req_pending == 1 and spi_tx_ready == 1 do
          req_pending = 0
        end
      end
    end
  end

  # Capture the returned byte and flip the completion toggle.
  on :axi_clk do
    if fclk_reset0_n == 0 do
      rx_data_reg = 0
      done_toggle = 0
    else
      if spi_rx_valid == 1 do
        rx_data_reg = spi_rx_data
        done_toggle = bxor(done_toggle, 1)
      end
    end
  end

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

  # DATA_CLK-domain producer bookkeeping: the packer's toggle delayed one
  # cycle (write strobe alignment — pk_word settles on the emit edge, the
  # BRAM write commits the edge after), and the counter producer at
  # DATA_CLK/4. pat_lo increments on the same edge its value commits, so
  # consecutive writes carry consecutive integers. No reset, per the
  # domain's rule: init values only, and the read side flushes itself.
  on :data_clk do
    pk_tog_d = pk_toggle

    if en_dclk == 1 and src_sel_dclk == 0 do
      ctr_div = ctr_div + 1

      if ctr_full == 1 do
        pat_lo = pat_lo + 1
      end
    else
      ctr_div = 0
    end

    # Inlined StreamBRAMFIFO write port. sb_wr_gray registers off
    # sb_wptr_next on the SAME edge as the write it describes, so the
    # synchronised pointer never claims an uncommitted word. No full
    # backpressure by design: a radio cannot be paused; a lap is detected
    # on the read side (count > 1024) and by SEQ holes.
    if sf_wr_en == 1 do
      sbuf[sb_wr_idx] = sf_wr_data
      sb_wr_ptr = sb_wptr_next
      sb_wr_gray = bxor(sb_wptr_next, sb_wptr_next >>> 1)
    end
  end

  # Inlined StreamBRAMFIFO read side: pointer synchroniser (never reset —
  # it tracks the writer) and the strobed read pointer. rd_rst re-aligns
  # to the synchronised write pointer: flush-to-empty without touching
  # the write domain.
  on :axi_clk do
    sb_wg_s0 = sb_wg_x
    sb_wg_s1 = sb_wg_s0
  end

  on :axi_clk do
    if sf_rd_rst == 1 do
      sb_rd_ptr = sb_wr_bin
    else
      if fifo_rd_en == 1 and sf_count != 0 do
        sb_rd_ptr = sb_rd_ptr + 1
      end
    end
  end

  # AXI-domain overrun watcher: latch the producer-lapped-the-consumer
  # condition sticky, count its rising edges, clear on EMIO command.
  on :axi_clk do
    if fclk_reset0_n == 0 do
      overrun_sticky = 0
      overrun_ctr = 0
      ov_prev = 0
    else
      ov_prev = sf_over

      if sf_over == 1 and ov_prev == 0 do
        overrun_sticky = 1
        overrun_ctr = overrun_ctr + 1
      end

      if stat_clear == 1 do
        overrun_sticky = 0
        overrun_ctr = 0
      end
    end
  end
end
