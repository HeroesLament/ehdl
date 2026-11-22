defmodule Hw.ECP5.ODDRX1F do
  @moduledoc """
  ECP5 output DDR register (X1 gearing), in the IOLOGIC beside the pad.

  `d0` goes out while `sclk` is high and `d1` while it is low, so the pad
  toggles at twice the SCLK rate. `q` must drive a pad directly (a top-level
  output or a `Hw.ECP5.OB`), nothing else.

  Also the standard way to forward a clock off-chip with a fixed phase:
  `d0: one, d1: zero` puts `sclk` itself on the pin through the IO register
  instead of through general routing.

  The ECP5 counterpart of `Hw.Xilinx.ODDR`.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :GSR, default: "ENABLED"

  input :sclk, 1
  input :rst, 1
  input :d0, 1
  input :d1, 1
  output :q, 1

  blackbox :oddr, "ODDRX1F",
    params: [GSR: :GSR],
    ports: [
      SCLK: :sclk,
      RST: :rst,
      D0: :d0,
      D1: :d1,
      Q: :q
    ]
end
