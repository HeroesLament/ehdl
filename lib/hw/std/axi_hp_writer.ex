defmodule Hw.AXIHPWriter do
  @moduledoc """
  AXI3 write-burst engine for the Zynq-7000 `S_AXI_HP` ports.

  Drains 64-bit words from a FIFO-shaped source into DDR through HP0 as
  INCR bursts into a ring buffer. The consuming side is the ARM, which
  mmaps the ring (a reserved, non-cached region — the same idiom as
  `DmaBuf` in nervezynq) and polls `write_ptr`. There is deliberately no
  dependency on `M_AXI_GP0` anywhere in this component: on the current
  LibreSDR firmware the GP path is dead (see nervezynq/HANDOFF.md), and
  this module plus EMIO GPIO (`Hw.PS7HP`) is the architecture that routes
  around it. HP is the PL *mastering* into the PS — the failure mode that
  hangs the CPU (a PS-initiated read into the PL that never answers)
  cannot occur on this path; a broken PL master starves, it cannot wedge
  the ARM.

  ## This is the engine, not the buffer

  The component holds no sample storage. It speaks a head-of-queue
  interface — `s_data` is the current head, `s_avail` says a full burst is
  available, `s_ren` consumes one word — which is exactly `Hw.FIFO`'s read
  port plus a threshold on its `count`:

      instance :fifo, Hw.FIFO, WIDTH: 64, DEPTH: 64, clk: :aclk, ...
      instance :dma, Hw.AXIHPWriter, aclk: :aclk, ...

      comb do
        dma.s_data  = fifo.rd_data
        dma.s_avail = fifo.count >= 16      # BURST_LEN
        fifo.rd_en  = dma.s_ren
      end

  The split is partly principle (storage policy is the instantiator's —
  depth, drop-on-full accounting, clock domain) and partly a measured
  constraint recorded here so nobody undoes it blind: **the EHDL simulator
  cannot yet execute `MemWrite` ops.** No design containing a written
  `memory` had ever been simulated before this one — the USB descriptor
  ROMs are init-only and lower to logic — so `Hw.Sim.Eval` has no
  `MemWrite` clause and `_top_`'s retained-op evaluation crashes on it
  (FunctionClauseError, eval.ex, first hit 2026-08-02). An engine with an
  internal `memory` FIFO therefore cannot be testbenched at all today.
  Memoryless, every line of the protocol logic simulates. Adding MemWrite
  to the simulator is a filed EHDL work item; when it lands, buffered
  compositions become simulable too — the synthesis path was never
  affected either way.

  ## The contract `s_avail` carries

  Asserting `s_avail` promises BURST_LEN consecutive words can be
  consumed, one per `s_ren`, without the head going invalid mid-burst.
  A FIFO with `count >= BURST_LEN` satisfies this by construction. The
  engine samples it only in `:idle`; once a burst starts it does not
  re-check, because AXI does not allow a write burst to pause for data on
  the master's initiative (WVALID low mid-burst stalls the interconnect
  for everyone sharing the port).

  ## Protocol shape (per burst)

      :idle       until s_avail and enable
      :send_addr  AWVALID until AWREADY        (one address, LEN = BURST_LEN-1)
      :send_data  WVALID for BURST_LEN beats, WLAST on the final one
      :wait_resp  BREADY high, wait BVALID; advance ring pointer

  One transaction outstanding at a time. That halves theoretical
  throughput versus pipelined AW/W and is still an order of magnitude
  beyond the radio's need: at 100 MHz, a pessimistic 50% bus efficiency is
  ~200 MB/s against ~128 MB/s for 16 Msps of 64-bit-packed I/Q.
  Single-outstanding also keeps the first silicon session legible: the
  PS7's WACOUNT/WCOUNT (exposed by `Hw.PS7HP`) cross-check against
  `bursts` directly — the same triage shape the devcfg DMA queue flags
  gave the readback instrument.

  ## Ring discipline (constraints the instantiator owns)

  - `ring_size` MUST be a power of two, and `base_addr` aligned to it.
    Wrapping is a mask, not a compare.
  - `BURST_LEN` MUST be 1..16 — AXI3 `AWLEN` is 4 bits; 17 would silently
    truncate to LEN=0. Nothing in elaboration checks a parameter range;
    the testbench pins the default.
  - Bursts are then always 4 KB-boundary-safe: 16 beats x 8 B = 128 B,
    aligned to 128 B, can never straddle a 4 KB page — AXI's one hard
    addressing rule, satisfied by construction rather than by checking.

  ## Status outputs are for EMIO, not AXI

  `write_ptr`, `bursts`, `bresp_errs` exist so a GP-less design can watch
  the engine: route a selection of bits to `Hw.PS7HP.emio_gpio_i` and read
  them from Linux GPIO. Overrun accounting (samples dropped because the
  FIFO was full) belongs to the FIFO side of the split, next to the
  storage it describes.

  ## AWCACHE, and what is deliberately absent

  AWCACHE = 0b0011: normal, non-cacheable, bufferable, modifiable — the
  setting for DDR via the non-coherent HP path where the CPU invalidates
  before reading. No read master yet (TX direction — `Hw.AXIHPReader`
  when the TX path exists), no QoS, no issuance capping.

  Nothing here has been on silicon; HP0 itself is UNV in SILICON_MAP
  terms. The testbench proves protocol shape against an ideal slave. The
  PS7's actual AWREADY/WREADY behaviour is what the first hardware
  session measures.
  """

  use Hw.Component

  # AXI3: 1..16 beats. See ring discipline above before touching.
  param :BURST_LEN, default: 16

  # Source read latency. 0 (default): the original combinational
  # head-of-queue contract — s_data IS the head, consumed by s_ren, next
  # head visible the same cycle (register-file FIFOs). 1: a PIPELINED
  # source — s_ren is a read strobe and the word it selects appears on
  # s_data one aclk later (a sync-read BRAM FIFO whose read address is a
  # register the strobe advances). In this mode the engine inserts one
  # dead cycle after every accepted beat (WVALID 1,0,1,0), because AXI
  # requires WDATA stable while WVALID is high and the next word simply
  # does not exist yet on the cycle after acceptance. Cost: beats take two
  # cycles, halving the streaming ceiling to ~400 MB/s at 100 MHz — still
  # ~6x the 16 Msps radio worst case. Gained: the FIFO storage can be a
  # dual-clock BRAM, which is what lets the LVDS and AXI clock domains
  # meet inside a hard block instead of fighting over fabric clock leaves
  # (the 0-for-167-seeds routing failure of 2026-08-03).
  param :PIPELINED_SOURCE, default: 0

  # freq: is load-bearing for simulation — Hw.Sim.Clock divides by it at
  # init, so a bare `clock :aclk` elaborates fine and then kills every
  # testbench with an ArithmeticError. 100 MHz matches FCLK0 on this board.
  clock :aclk, freq: 100.0
  input :aresetn, 1   # Active-low, AXI convention (PS7 FCLKRESETN0 after sync)

  # --- Head-of-queue source (Hw.FIFO read port shape) -------------------------
  input :s_data, 64
  input :s_avail, 1
  output :s_ren, 1

  # --- Configuration (static or quasi-static; see ring discipline) ------------
  input :base_addr, 32
  input :ring_size, 32
  input :enable, 1

  # --- Status (for EMIO / debug) -----------------------------------------------
  output :write_ptr, 32
  output :bursts, 16
  output :bresp_errs, 8

  # --- AXI3 write address channel -----------------------------------------------
  output :m_axi_awid, 6
  output :m_axi_awaddr, 32
  output :m_axi_awlen, 4
  output :m_axi_awsize, 2
  output :m_axi_awburst, 2
  output :m_axi_awlock, 2
  output :m_axi_awcache, 4
  output :m_axi_awprot, 3
  output :m_axi_awqos, 4
  output :m_axi_awvalid, 1
  input :m_axi_awready, 1

  # --- AXI3 write data channel ----------------------------------------------------
  output :m_axi_wid, 6
  output :m_axi_wdata, 64
  output :m_axi_wstrb, 8
  output :m_axi_wlast, 1
  output :m_axi_wvalid, 1
  input :m_axi_wready, 1

  # --- AXI3 write response channel --------------------------------------------------
  input :m_axi_bid, 6
  input :m_axi_bresp, 2
  input :m_axi_bvalid, 1
  output :m_axi_bready, 1

  # --- Burst state -------------------------------------------------------------------
  wire :beat_count, 4
  wire :current_addr, 32

  wire :rst, 1
  wire :is_last_beat, 1
  wire :in_send_data, 1
  wire :in_wait_resp, 1

  comb do
    rst = bnot(aresetn)

    is_last_beat = beat_count == BURST_LEN - 1

    write_ptr = current_addr

    # Head-of-queue passthrough: the beat on the bus is always the head,
    # consumed exactly when the slave accepts it. Gating on WVALID rather
    # than in_send_data is identical for the combinational source (the two
    # signals are set and cleared together in :send_data) and is what makes
    # the PIPELINED_SOURCE gap cycles consume nothing.
    m_axi_wdata = s_data
    m_axi_wlast = is_last_beat
    s_ren = band(m_axi_wvalid, m_axi_wready)

    # Constant channel fields. AWSIZE is 2 bits on the PS7 HP port; the
    # value 3 (0b11) is the low two bits of AxSIZE 0b011 = 8 bytes/beat.
    m_axi_awid = 0
    m_axi_wid = 0
    m_axi_awlen = BURST_LEN - 1
    m_axi_awsize = 3
    m_axi_awburst = 1
    m_axi_awlock = 0
    m_axi_awcache = 3
    m_axi_awprot = 0
    m_axi_awqos = 0
    m_axi_wstrb = 0xFF
    m_axi_bready = 1
  end

  # The handshake structure below, including which side of each handshake a
  # transition may test, is inherited from Hw.AXI4Master and its comments —
  # that reasoning survived review; the protocol widths around it did not.
  #
  # reset: :rst is load-bearing. Without it the `on :aclk` blocks clear the
  # beat counter and address on reset while this FSM stays wherever it was —
  # potentially mid-burst with WVALID asserted against a PS that has just
  # been reset, which wedges the AXI interconnect.
  fsm :state, clock: :aclk, reset: :rst, init: :idle do
    defaults do
      m_axi_awvalid = 0
      m_axi_wvalid = 0
      in_send_data = 0
      in_wait_resp = 0
    end

    case state do
      :idle ->
        on enable == 1 and s_avail == 1, next: :send_addr

      :send_addr ->
        # AWVALID is registered, so it is LOW on the first cycle of this
        # state. Testing AWREADY alone would advance against a slave that
        # parks AWREADY high — and the Zynq PS ports do park it high.
        m_axi_awaddr = current_addr
        m_axi_awvalid = 1

        on m_axi_awvalid == 1 and m_axi_awready == 1 do
          m_axi_awvalid = 0
          next :send_data
        end

      :send_data ->
        # in_send_data must be cleared alongside WVALID: leaving it asserted
        # into :wait_resp would confuse the beat accounting below.
        #
        # PIPELINED_SOURCE inserts one dead cycle after every accepted beat:
        # the acceptance is visible combinationally (WVALID and WREADY both
        # high NOW), and the registered assignment lands next cycle — which
        # is exactly the cycle the strobed word is still in flight from the
        # BRAM. A stalled beat (WREADY low) keeps WVALID high and the data
        # held, per AXI stability rules.
        if PIPELINED_SOURCE == 0 do
          m_axi_wvalid = 1
        else
          if m_axi_wvalid == 1 and m_axi_wready == 1 do
            m_axi_wvalid = 0
          else
            m_axi_wvalid = 1
          end
        end

        in_send_data = 1

        on m_axi_wvalid == 1 and m_axi_wready == 1 and is_last_beat == 1 do
          m_axi_wvalid = 0
          in_send_data = 0
          next :wait_resp
        end

      :wait_resp ->
        # Guarded on in_wait_resp so this transition and the address update
        # below fire on the same cycle — testing BVALID alone would let the
        # first cycle of this state transition without advancing the ring.
        in_wait_resp = 1

        on in_wait_resp == 1 and m_axi_bvalid == 1 do
          in_wait_resp = 0
          next :idle
        end
    end
  end

  # Beat counter. Advances on ACCEPTED beats (WVALID and WREADY), which is
  # the same as the old in_send_data gating for the combinational source
  # and correct for the pipelined one (gap cycles have WVALID low).
  on :aclk do
    if rst == 1 do
      beat_count = 0
    else
      if m_axi_wvalid == 1 and m_axi_wready == 1 do
        if is_last_beat == 1 do
          beat_count = 0
        else
          beat_count = beat_count + 1
        end
      end
    end
  end

  # Ring address, advanced on write response. The mask form is why
  # ring_size must be a power of two and base_addr aligned to it.
  on :aclk do
    if rst == 1 do
      current_addr = base_addr
      bursts = 0
      bresp_errs = 0
    else
      if in_wait_resp == 1 and m_axi_bvalid == 1 do
        current_addr =
          base_addr + band(current_addr - base_addr + BURST_LEN * 8, ring_size - 1)

        bursts = bursts + 1

        if m_axi_bresp != 0 do
          bresp_errs = bresp_errs + 1
        end
      end
    end
  end
end
