defmodule Hw.ECP5.CLKDIVF do
  @moduledoc """
  ECP5 clock divider, `DIV` one of `"2.0"`, `"3.5"`, `"4.0"`. Normally fed from
  an edge clock (`Hw.ECP5.ECLKSYNCB`) to make the SCLK of an IO gearbox.
  `alignwd` slips the divided clock by one input cycle for word alignment.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :GSR, default: "DISABLED"
  param :DIV, default: "2.0"

  input :clki, 1
  input :rst, 1
  input :alignwd, 1
  output :cdivx, 1

  blackbox :clkdiv, "CLKDIVF",
    params: [GSR: :GSR, DIV: :DIV],
    ports: [
      CLKI: :clki,
      RST: :rst,
      ALIGNWD: :alignwd,
      CDIVX: :cdivx
    ]
end
