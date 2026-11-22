defmodule Hw.ECP5.DCSC do
  @moduledoc """
  ECP5 dynamic clock select: glitch-free mux of two global clocks.

  `sel1` / `sel0` pick CLK1 / CLK0; `modesel` high bypasses the glitch-free
  logic. `DCSMODE` (default `"POS"`) selects the switching behaviour; the
  modes are listed in Lattice TN-02200.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :DCSMODE, default: "POS"

  input :clk1, 1
  input :clk0, 1
  input :sel1, 1
  input :sel0, 1
  input :modesel, 1
  output :dcsout, 1

  blackbox :dcsc, "DCSC",
    params: [DCSMODE: :DCSMODE],
    ports: [
      CLK1: :clk1,
      CLK0: :clk0,
      SEL1: :sel1,
      SEL0: :sel0,
      MODESEL: :modesel,
      DCSOUT: :dcsout
    ]
end
