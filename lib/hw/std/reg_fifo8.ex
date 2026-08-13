defmodule Hw.RegFIFO8 do
  @moduledoc """
  8-deep first-word-fall-through FIFO built from registers — no `memory`.

  The shallow sibling of `Hw.RegFIFO16`, and the one the LibreSDR stream
  revision actually ships. Same rationale (no distributed-RAM primitive for
  the router to meet for the first time; memoryless so compositions stay
  simulable) — see RegFIFO16's moduledoc for the full argument. This one
  exists because clock-leaf routing said so, with numbers:

  With the 16-deep FIFO the streaming netlist failed 46/46 seeds on
  `axi_clk -> SLICE CLKINV_OUT`, and the router debug trace showed 660 of
  the blocked leaf clock wires held by `data_clk` (2026-08-03). ~1,100 new
  AXI-domain flops had pushed `axi_clk` sinks into rows whose clock leaves
  the LVDS domain already owned. Halving the FIFO (512 fewer flops, 8:1
  mux instead of 16:1) pulls the AXI clock load back toward the footprint
  the previous netlist routed with.

  Pair with `Hw.AXIHPWriter` at `BURST_LEN: 4` and gate `s_avail` on
  `count >= 4`: a committed burst drains 4 beats in ~4 consumer cycles
  while the producer (≤ 1 word per 6.5 consumer cycles at the AD9363's
  61.44 MHz DATA_CLK ceiling) can add at most one — 8 slots never overrun
  mid-burst. Counter-mode writers should gate on `count < 6` so the one
  in-flight registered write can never be dropped.
  """

  use Hw.Component

  param :WIDTH, default: 64

  # 100 MHz matches FCLK0 on this board. freq: is load-bearing for
  # simulation (Hw.Sim.Clock divides by it at init).
  clock :clk, freq: 100.0

  input :rst, 1
  input :wr_en, 1
  input :wr_data, WIDTH
  input :rd_en, 1
  output :rd_data, WIDTH
  output :empty, 1
  output :full, 1
  output :count, 4

  wire :r0, WIDTH, init: 0
  wire :r1, WIDTH, init: 0
  wire :r2, WIDTH, init: 0
  wire :r3, WIDTH, init: 0
  wire :r4, WIDTH, init: 0
  wire :r5, WIDTH, init: 0
  wire :r6, WIDTH, init: 0
  wire :r7, WIDTH, init: 0

  wire :wr_ptr, 3, init: 0
  wire :rd_ptr, 3, init: 0
  wire :cnt, 4, init: 0
  wire :do_wr, 1
  wire :do_rd, 1

  comb do
    count = cnt
    empty = cnt == 0
    full = cnt == 8
    do_wr = band(wr_en, bnot(full))
    do_rd = band(rd_en, bnot(empty))

    # 8:1 read mux. ALL arms explicit: an hdl_case no-match yields 0, it
    # does NOT retain an earlier default assignment (measured in
    # RegFIFO16's testbench, 2026-08-03 — r0 read as 0 until the <<0>>
    # arm was added).
    rd_data = r0

    hdl_case <<rd_ptr::3>> do
      <<0::3>> -> rd_data = r0
      <<1::3>> -> rd_data = r1
      <<2::3>> -> rd_data = r2
      <<3::3>> -> rd_data = r3
      <<4::3>> -> rd_data = r4
      <<5::3>> -> rd_data = r5
      <<6::3>> -> rd_data = r6
      <<7::3>> -> rd_data = r7
    end
  end

  on :clk do
    if rst == 1 do
      wr_ptr = 0
      rd_ptr = 0
      cnt = 0
    else
      if do_wr == 1 do
        if wr_ptr == 0 do
          r0 = wr_data
        end

        if wr_ptr == 1 do
          r1 = wr_data
        end

        if wr_ptr == 2 do
          r2 = wr_data
        end

        if wr_ptr == 3 do
          r3 = wr_data
        end

        if wr_ptr == 4 do
          r4 = wr_data
        end

        if wr_ptr == 5 do
          r5 = wr_data
        end

        if wr_ptr == 6 do
          r6 = wr_data
        end

        if wr_ptr == 7 do
          r7 = wr_data
        end

        wr_ptr = wr_ptr + 1
      end

      if do_rd == 1 do
        rd_ptr = rd_ptr + 1
      end

      if do_wr == 1 and do_rd == 0 do
        cnt = cnt + 1
      end

      if do_rd == 1 and do_wr == 0 do
        cnt = cnt - 1
      end
    end
  end
end
