defmodule Hw.ECP5.GSR do
  @moduledoc """
  ECP5 global set/reset: `gsr` low asserts the global reset of every flop and
  IO register that has GSR enabled (the `GSR: "ENABLED"` default on
  `Hw.ECP5.IDDRX1F` / `ODDRX1F`, and fabric flops under nextpnr). Active low.

  EHDL designs reset through their own clock-domain resets; this exists for
  logic that has to follow the chip-wide reset instead.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  input :gsr, 1

  blackbox :gsr, "GSR", ports: [GSR: :gsr]
end
