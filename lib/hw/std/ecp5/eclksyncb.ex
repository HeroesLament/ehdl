defmodule Hw.ECP5.ECLKSYNCB do
  @moduledoc """
  ECP5 edge clock synchroniser: the stoppable buffer between a PLL output and
  an edge clock, used by the X2 / X4 IO gearing and by the `Hw.ECP5.CLKDIVF`
  that derives its SCLK. `stop` high holds the edge clock.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  input :eclki, 1
  input :stop, 1
  output :eclko, 1

  blackbox :eclksync, "ECLKSYNCB",
    ports: [
      ECLKI: :eclki,
      STOP: :stop,
      ECLKO: :eclko
    ]
end
