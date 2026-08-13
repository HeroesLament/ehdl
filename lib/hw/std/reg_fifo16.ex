defmodule Hw.RegFIFO16 do
  @moduledoc """
  16-deep first-word-fall-through FIFO built from registers — no `memory`.

  ## Why not `Hw.FIFO`

  Two reasons, both project-specific and both worth money:

  1. **Routability.** `Hw.FIFO`'s asynchronous-read `memory` infers
     distributed RAM (RAM32M/RAM64M), a primitive class this openXC7 flow
     has never put on silicon. This design's routing history (one seed in
     377, then 755 failures traced to INV cells and CE pins) says: do not
     hand nextpnr a new primitive class inside the streaming revision.
     Registers and muxes are exactly the structures the established
     `dffunmap` workaround already tames.

  2. **Simulability.** The EHDL simulator cannot execute `MemWrite` ops, so
     any `memory`-based FIFO is untestable today (the constraint that shaped
     `Hw.AXIHPWriter` — see its moduledoc). This FIFO is pure registers, so
     the full packer → FIFO → HP-writer composition can be testbenched,
     which no `memory` FIFO composition can.

  The cost is area — 16 × WIDTH flops plus a 16:1 read mux — which at
  WIDTH=64 is ~1k flops on a part with 53k. Do not scale DEPTH up by
  copy-paste; past ~32 the mux depth starts to matter and a BRAM FIFO with
  a skid buffer becomes the right component instead.

  ## Read semantics: first-word-fall-through

  `rd_data` is combinationally the oldest word whenever `empty == 0` —
  the head-of-queue shape `Hw.AXIHPWriter.s_data` requires. `rd_en`
  consumes: the NEXT word appears on `rd_data` the following cycle.
  This matches the burst engine's `s_ren = in_send_data and wready`
  consumption exactly: the beat on the bus is always the head.

  ## Guards

  Writes while full and reads while empty are ignored (`do_wr`/`do_rd`
  gating). The instantiator sees drops only if it chooses not to check
  `full`/`count` — which is a policy decision that belongs there, along
  with any drop accounting (per `Hw.AXIHPWriter`'s split: storage policy
  is the instantiator's).

  With `Hw.AXIHPWriter` at `BURST_LEN: 8`, gate `s_avail` on `count >= 8`:
  the burst drains 8 while up to 8 more arrive, and 16 total slots mean a
  producer at ≤ 1 word per ~1.5 consumer cycles can never overrun during
  a burst. The LVDS packer produces one word per 4 DATA_CLK (≤ 15.4 MHz
  at the AD9363's 61.44 MHz ceiling) against a 100 MHz drain — margin ~6x.
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
  output :count, 5

  wire :r0, WIDTH, init: 0
  wire :r1, WIDTH, init: 0
  wire :r2, WIDTH, init: 0
  wire :r3, WIDTH, init: 0
  wire :r4, WIDTH, init: 0
  wire :r5, WIDTH, init: 0
  wire :r6, WIDTH, init: 0
  wire :r7, WIDTH, init: 0
  wire :r8, WIDTH, init: 0
  wire :r9, WIDTH, init: 0
  wire :r10, WIDTH, init: 0
  wire :r11, WIDTH, init: 0
  wire :r12, WIDTH, init: 0
  wire :r13, WIDTH, init: 0
  wire :r14, WIDTH, init: 0
  wire :r15, WIDTH, init: 0

  wire :wr_ptr, 4, init: 0
  wire :rd_ptr, 4, init: 0
  wire :cnt, 5, init: 0
  wire :do_wr, 1
  wire :do_rd, 1

  comb do
    count = cnt
    empty = cnt == 0
    full = cnt == 16
    do_wr = band(wr_en, bnot(full))
    do_rd = band(rd_en, bnot(empty))

    # 16:1 read mux on the read pointer. Default first, like the AXI-Lite
    # slave's register read mux — but note the explicit <<0::4>> arm: an
    # hdl_case arm that matches OVERRIDES the default, while a no-match
    # yields 0 rather than retaining the earlier assignment (measured in
    # this component's own testbench, 2026-08-03: every slot read fine
    # except r0, which read 0). The slave's mux never saw this because its
    # default IS 0. All 16 arms are therefore explicit.
    rd_data = r0

    hdl_case <<rd_ptr::4>> do
      <<0::4>> -> rd_data = r0
      <<1::4>> -> rd_data = r1
      <<2::4>> -> rd_data = r2
      <<3::4>> -> rd_data = r3
      <<4::4>> -> rd_data = r4
      <<5::4>> -> rd_data = r5
      <<6::4>> -> rd_data = r6
      <<7::4>> -> rd_data = r7
      <<8::4>> -> rd_data = r8
      <<9::4>> -> rd_data = r9
      <<10::4>> -> rd_data = r10
      <<11::4>> -> rd_data = r11
      <<12::4>> -> rd_data = r12
      <<13::4>> -> rd_data = r13
      <<14::4>> -> rd_data = r14
      <<15::4>> -> rd_data = r15
    end
  end

  on :clk do
    if rst == 1 do
      wr_ptr = 0
      rd_ptr = 0
      cnt = 0
    else
      if do_wr == 1 do
        # Write decode: the same explicit-branch shape as the capture
        # buffer's bank decode in LibreSDRRadio.Top — proven to route.
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

        if wr_ptr == 8 do
          r8 = wr_data
        end

        if wr_ptr == 9 do
          r9 = wr_data
        end

        if wr_ptr == 10 do
          r10 = wr_data
        end

        if wr_ptr == 11 do
          r11 = wr_data
        end

        if wr_ptr == 12 do
          r12 = wr_data
        end

        if wr_ptr == 13 do
          r13 = wr_data
        end

        if wr_ptr == 14 do
          r14 = wr_data
        end

        if wr_ptr == 15 do
          r15 = wr_data
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
