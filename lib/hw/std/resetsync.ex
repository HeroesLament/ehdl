defmodule Hw.ResetSync do
  @moduledoc """
  Two-flop reset synchronizer with hold counter.

  Generates a clean synchronous reset from an async ready signal
  (e.g. pll_locked). Holds rst_out asserted for HOLD_CYCLES after
  rst_in stabilizes high. Any glitch on rst_in restarts the counter.

  ## Why reset_style: :none

  This component IS the reset generator — it cannot be gated by the
  reset it produces. `clock :clk, reset_style: :none` tells the
  elaborator to emit a bare `always @(posedge clk)` block with no
  `if (rst)` wrapper. Initial state comes from `init:` values on
  the wire declarations, which map to Verilog FF initializers.

  ## Usage

      instance :rst_sync, Hw.ResetSync,
        HOLD_CYCLES: 1024,
        clk:         :clk_48,
        rst_in:      :pll_locked,
        rst_out:     :rst
  """

  use Hw.Component

  param :HOLD_CYCLES, default: 1024

  # reset_style: :none — this clock domain has no external reset gating.
  # The elaborator emits a bare always @(posedge clk) block.
  # Initial register values come from init: declarations below.
  clock :clk, reset_style: :none

  input  :rst_in,  1
  output :rst_out, 1

  wire :sync0,   1,  init: 0
  wire :sync1,   1,  init: 0
  wire :counter, 11, init: 0
  wire :ready,   1,  init: 0

  comb do
    rst_out = bnot(ready)
  end

  on :clk do
    sync0 = rst_in
    sync1 = sync0

    if bnot(sync1) do
      counter = 0
      ready   = 0
    else
      if counter == HOLD_CYCLES - 1 do
        ready = 1
      else
        counter = counter + 1
      end
    end
  end
end
