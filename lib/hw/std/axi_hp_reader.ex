defmodule Hw.AXIHPReader do
  @moduledoc """
  AXI3 read-burst engine for the Zynq-7000 `S_AXI_HP` ports: the TX-direction
  mirror of `Hw.AXIHPWriter`.

  Reads 64-bit words out of a DDR ring buffer as INCR bursts and pushes them
  into a FIFO-shaped sink. The producing side is the ARM, which writes
  records into the ring (a reserved `no-map` region, same idiom as the HP0 RX
  ring) and publishes how far it has written through `head_addr` (a doorbell:
  EMIO or an AXI-lite register, instantiator's choice). Design context:
  nervezynq notes/ocusync/09-ps-ingest-and-tx-dma.md.

  As with the writer, the PL is the AXI *master* here. A broken PL master
  starves; it cannot wedge the ARM the way a PS-initiated read into a dead
  PL slave can.

  ## This is the engine, not the buffer

  Same split as the writer, mirrored. The sink is `Hw.FIFO`'s write port
  plus a threshold on free space:

      instance :fifo, Hw.FIFO, WIDTH: 64, DEPTH: 64, clk: :aclk, ...
      instance :dma, Hw.AXIHPReader, aclk: :aclk, ...

      comb do
        fifo.wr_data = dma.m_data
        fifo.wr_en   = dma.m_wen
        dma.m_space  = (DEPTH - fifo.count) >= 16    # BURST_LEN
      end

  No internal `memory`, for the reason the writer records: the EHDL
  simulator cannot execute `MemWrite`, so a component holding storage could
  not be testbenched. A structure test pins this.

  ## The contract `m_space` carries

  Asserting `m_space` promises BURST_LEN consecutive words can be accepted
  without back-pressure. The engine samples it only in `:idle`; once the
  address is issued, RREADY stays high for the whole burst. AXI would allow
  RREADY to drop mid-burst, but holding read data inside the interconnect
  stalls everything sharing the port, and the sink contract makes it
  unnecessary.

  ## The contract `head_addr` carries (producer rule)

  `head_addr` is the absolute address one past the last byte the producer
  has made visible. A burst is issued only when at least `BURST_LEN * 8`
  bytes lie between `read_ptr` and `head_addr` (modulo the ring). So:

  - The producer must publish `head_addr` only on `BURST_LEN * 8` (128 B)
    boundaries, or the tail of what it wrote is not read until more follows.
    `OcuSync.Ring` records are 32 B aligned, so a producer ending mid-burst
    must pad to the next 128 B boundary before ringing the doorbell. (A
    filler record type for that is not defined yet; see note 09.)
  - Empty is `head_addr == read_ptr`. The producer must keep at least one
    burst free, or a full ring reads as empty. `OcuSync.Ring` keeps one
    32 B unit free; this engine needs 128 B. The producer's ring must use
    the larger of the two.
  - Before exposing `head_addr`, the producer must make its writes visible
    to the HP port (the ring is mapped non-cacheable, so a store barrier is
    enough). The engine reads what DDR holds.

  ## Protocol shape (per burst)

      :idle       until enable, a full burst is readable, and m_space
      :send_addr  ARVALID until ARREADY          (one address, LEN = BURST_LEN-1)
      :recv_data  RREADY high; push every RVALID beat; leave after BURST_LEN

  One transaction outstanding. Per the writer's arithmetic, single
  outstanding at 100 MHz is an order of magnitude beyond the radio's need.

  The engine counts beats itself and leaves `:recv_data` on its own count.
  RLAST is checked against that count rather than trusted: a mismatch
  increments `rlast_errs`, the first thing to look at if the PS ever
  delivers a burst of the wrong length.

  ## Ring discipline (instantiator owns these)

  Identical to the writer: `ring_size` a power of two, `base_addr` aligned
  to it, `BURST_LEN` 1..16 (AXI3 `ARLEN` is 4 bits), so a 128 B burst
  aligned to 128 B never crosses a 4 KB boundary.

  ## ARCACHE

  0b0011, same as the writer's AWCACHE: normal, non-cacheable, bufferable,
  modifiable. DDR via the non-coherent HP path.

  ## Status outputs are for EMIO, not AXI

  `read_ptr` is the tail the producer needs for credit: space free is
  `ring_size - ((head - read_ptr) mod ring_size) - BURST_LEN * 8`.
  `bursts`, `rresp_errs`, `rlast_errs` are triage counters.

  Nothing here has been on silicon. `Hw.PS7HP` does not expose an HP read
  channel yet; this component is tested against an ideal slave only.
  """

  use Hw.Component

  # AXI3: 1..16 beats. See ring discipline before touching.
  param :BURST_LEN, default: 16

  # freq: is load-bearing for simulation (see Hw.AXIHPWriter).
  clock :aclk, freq: 100.0
  input :aresetn, 1

  # --- Sink (Hw.FIFO write port shape) ------------------------------------------
  output :m_data, 64
  output :m_wen, 1
  input :m_space, 1

  # --- Configuration --------------------------------------------------------------
  input :base_addr, 32
  input :ring_size, 32
  input :head_addr, 32
  input :enable, 1

  # --- Status (for EMIO / debug) ----------------------------------------------------
  output :read_ptr, 32
  output :bursts, 16
  output :rresp_errs, 8
  output :rlast_errs, 8

  # --- AXI3 read address channel ------------------------------------------------------
  output :m_axi_arid, 6
  output :m_axi_araddr, 32
  output :m_axi_arlen, 4
  output :m_axi_arsize, 2
  output :m_axi_arburst, 2
  output :m_axi_arlock, 2
  output :m_axi_arcache, 4
  output :m_axi_arprot, 3
  output :m_axi_arqos, 4
  output :m_axi_arvalid, 1
  input :m_axi_arready, 1

  # --- AXI3 read data channel ------------------------------------------------------------
  input :m_axi_rid, 6
  input :m_axi_rdata, 64
  input :m_axi_rresp, 2
  input :m_axi_rlast, 1
  input :m_axi_rvalid, 1
  output :m_axi_rready, 1

  # --- Burst state ------------------------------------------------------------------------
  wire :beat_count, 4
  wire :current_addr, 32
  wire :fill, 32

  wire :rst, 1
  wire :is_last_beat, 1
  wire :in_recv, 1
  wire :beat_ok, 1
  wire :readable, 1
  wire :go, 1

  comb do
    rst = bnot(aresetn)

    is_last_beat = beat_count == BURST_LEN - 1
    read_ptr = current_addr

    # Bytes between tail and head, modulo the ring (mask: power-of-two ring).
    fill = band(head_addr - current_addr, ring_size - 1)
    readable = fill >= BURST_LEN * 8
    go = band(band(enable, readable), m_space)

    # RREADY follows the registered in-burst flag. It is low on the first
    # cycle of :recv_data, which costs one cycle per burst and keeps the
    # accept condition a single registered term.
    m_axi_rready = in_recv
    beat_ok = band(m_axi_rvalid, in_recv)

    # Sink push: exactly the accepted beats, data straight off RDATA.
    m_wen = beat_ok
    m_data = m_axi_rdata

    # Constant channel fields. ARSIZE is the PS7 primitive's 2-bit field;
    # 3 = AxSIZE 0b011 = 8 bytes/beat.
    m_axi_arid = 0
    m_axi_arlen = BURST_LEN - 1
    m_axi_arsize = 3
    m_axi_arburst = 1
    m_axi_arlock = 0
    m_axi_arcache = 3
    m_axi_arprot = 0
    m_axi_arqos = 0
  end

  # Handshake structure inherited from Hw.AXIHPWriter (and through it
  # Hw.AXI4Master): registered VALID, so every handshake tests both sides.
  # reset: :rst is load-bearing for the same reason as the writer's: the
  # FSM must not survive a reset mid-burst with ARVALID or RREADY asserted.
  fsm :state, clock: :aclk, reset: :rst, init: :idle do
    defaults do
      m_axi_arvalid = 0
      in_recv = 0
    end

    case state do
      :idle ->
        on go == 1, next: :send_addr

      :send_addr ->
        # ARVALID is registered, so LOW on this state's first cycle. Testing
        # ARREADY alone would advance against a slave that parks ARREADY
        # high, which the PS ports do.
        m_axi_araddr = current_addr
        m_axi_arvalid = 1

        on m_axi_arvalid == 1 and m_axi_arready == 1 do
          m_axi_arvalid = 0
          next :recv_data
        end

      :recv_data ->
        in_recv = 1

        on in_recv == 1 and m_axi_rvalid == 1 and is_last_beat == 1 do
          in_recv = 0
          next :idle
        end
    end
  end

  # Beat counter: advances on accepted beats only, so RVALID gaps cost
  # nothing and count nothing.
  on :aclk do
    if rst == 1 do
      beat_count = 0
    else
      if beat_ok == 1 do
        if is_last_beat == 1 do
          beat_count = 0
        else
          beat_count = beat_count + 1
        end
      end
    end
  end

  # Ring tail and triage counters. The tail advances when the last beat of a
  # burst is accepted, i.e. when the sink already holds the whole burst.
  on :aclk do
    if rst == 1 do
      current_addr = base_addr
      bursts = 0
      rresp_errs = 0
      rlast_errs = 0
    else
      if beat_ok == 1 do
        if m_axi_rresp != 0 do
          rresp_errs = rresp_errs + 1
        end

        if m_axi_rlast != is_last_beat do
          rlast_errs = rlast_errs + 1
        end

        if is_last_beat == 1 do
          current_addr =
            base_addr + band(current_addr - base_addr + BURST_LEN * 8, ring_size - 1)

          bursts = bursts + 1
        end
      end
    end
  end
end
