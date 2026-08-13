defmodule Hw.StreamBRAMFIFO do
  @moduledoc """
  Dual-clock 1024 x 64 stream FIFO whose storage is a true dual-port BRAM —
  the clock-domain crossing happens INSIDE the RAMB36 pair, not in fabric.

  ## Why this exists (the routing history, so nobody undoes it blind)

  The first streaming revision crossed the LVDS->AXI boundary with a
  toggle-stabilised 64-bit bus into a register FIFO. It was simulable and
  correct — and unroutable: 0 of 167 seeds, every failure a clock leaf
  (`SLICE CLKINV_OUT`), with the router debug trace showing each clock's
  leaf wires held by the other net (660 held by data_clk against axi_clk
  on the 16-deep FIFO; 413 held by axi_clk against data_clk on the 8-deep
  one, 2026-08-03). The 64 cross-domain data wires gave the placer a hard
  affinity between the two clock islands, interleaving their flops in the
  same tiles, and nextpnr-xilinx cannot feed two clocks into the leaf rows
  at that density.

  This design already contains the counter-example, silicon-proven eight
  times over: the capture banks, written on DATA_CLK and read on AXI_CLK,
  crossing inside BRAM. This component is that idiom with pointers.

  What crosses in fabric here is ONE 11-bit gray-coded write pointer,
  through per-bit 2-flop synchronisers — safe because a gray code changes
  one bit per increment, so any sampling skew yields a recent-valid value,
  never a torn one. The read side's view of `count` is therefore
  conservative (may lag), never optimistic.

  ## Contracts

  * Write side (`wr_clk`, the LVDS DATA_CLK domain): no reset, per that
    domain's rule — init values only. `wr_en` writes `wr_data` and
    advances. There is NO full backpressure: a radio cannot be paused, so
    a producer that laps the consumer simply overwrites — the consumer
    detects it as `count > 1024` (and, for packed radio words, as SEQ
    holes). Word writes are atomic, so laps corrupt nothing mid-word.
  * Read side (`rd_clk`): `rd_data` is `buf[rd_ptr]` through the BRAM's
    sync-read port — a STROBED, one-cycle-latency head: `rd_en` advances
    the pointer and the new head appears on `rd_data` the following cycle.
    Pair with `Hw.AXIHPWriter, PIPELINED_SOURCE: 1`, which exists for
    exactly this contract. `rd_rst` re-aligns `rd_ptr` to the synchronised
    write pointer — flush-to-empty without ever resetting the write side.

  `count` is 11 bits: 0..1024 healthy, above 1024 means the producer has
  lapped since the last flush (sticky-flag it upstream).

  Contains a written `memory`, so THIS component cannot be simulated until
  the EHDL MemWrite work item lands — the same standing exception as the
  capture banks. Everything around the memory (packer, engine with its
  pipelined mode) stays memoryless and testbenched; the BRAM construct
  itself rides on the capture banks' silicon record.
  """

  use Hw.Component

  # LVDS DATA_CLK measures 32.01 MHz at the 8 Msps V1 operating point;
  # 100 MHz matches FCLK0. freq: is load-bearing for simulation.
  clock :wr_clk, freq: 32.0
  clock :rd_clk, freq: 100.0

  input :wr_en, 1
  input :wr_data, 64

  input :rd_rst, 1
  input :rd_en, 1
  output :rd_data, 64
  output :count, 11

  # Storage: 1024 x 64, one array — two RAMB36 side by side, no depth
  # cascade, so none of the address-decode INV plague (the 8192-deep
  # lesson in LibreSDRRadio.Top's capture comments).
  memory :buf, width: 64, depth: 1024, sync_read: :rd_clk

  # Write domain
  wire :wr_ptr, 11, init: 0
  wire :wr_gray, 11, init: 0
  wire :wr_ptr_next, 11
  wire :wr_idx, 10

  # Read domain
  wire :wg_s0, 11, init: 0
  wire :wg_s1, 11, init: 0
  wire :wr_bin, 11
  wire :gb1, 11
  wire :gb2, 11
  wire :gb4, 11
  wire :rd_ptr, 11, init: 0
  wire :rd_idx, 10

  comb do
    wr_ptr_next = wr_ptr + 1
    wr_idx = wr_ptr[9..0]
    rd_idx = rd_ptr[9..0]

    # Gray -> binary: log-depth parallel prefix XOR over 11 bits.
    gb1 = bxor(wg_s1, wg_s1 >>> 1)
    gb2 = bxor(gb1, gb1 >>> 2)
    gb4 = bxor(gb2, gb2 >>> 4)
    wr_bin = bxor(gb4, gb4 >>> 8)

    # 11-bit modular difference; healthy range 0..1024.
    count = wr_bin - rd_ptr

    rd_data = buf[rd_idx]
  end

  # Write domain: no reset (DATA_CLK may not exist yet; init values only).
  # wr_gray is registered off wr_ptr_next on the SAME edge as the write it
  # describes, so the synchronised pointer never claims an uncommitted word.
  on :wr_clk do
    if wr_en == 1 do
      buf[wr_idx] = wr_data
      wr_ptr = wr_ptr_next
      wr_gray = bxor(wr_ptr_next, wr_ptr_next >>> 1)
    end
  end

  # Read domain: pointer synchroniser (never reset by rd_rst — it tracks
  # the writer) and the strobed read pointer.
  on :rd_clk do
    wg_s0 = wr_gray
    wg_s1 = wg_s0
  end

  on :rd_clk do
    if rd_rst == 1 do
      rd_ptr = wr_bin
    else
      if rd_en == 1 and count != 0 do
        rd_ptr = rd_ptr + 1
      end
    end
  end
end
