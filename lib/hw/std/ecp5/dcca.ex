defmodule Hw.ECP5.DCCA do
  @moduledoc """
  ECP5 primary clock buffer with clock enable: drives a net onto one of the
  global clock trees.

  nextpnr promotes high-fanout clocks to a DCCA on its own; instantiating one
  pins the choice instead of leaving it to the promoter, and is the only way to
  gate a global clock. (oxibit-ecp5 inserts its own DCCA per clock and does
  not yet accept an instantiated one.)

  `ce` low holds the output low. Tie it to a one wire for an ungated buffer.

      instance :buf, Hw.ECP5.DCCA, clki: :pll_clkop, ce: :one, clko: :clk_48

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  input :clki, 1
  input :ce, 1
  output :clko, 1

  blackbox :dcca, "DCCA",
    ports: [
      CLKI: :clki,
      CE: :ce,
      CLKO: :clko
    ]
end
