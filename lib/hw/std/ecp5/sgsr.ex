defmodule Hw.ECP5.SGSR do
  @moduledoc """
  ECP5 `SGSR`. Synchronous global set / reset: GSR low resets every register with GSR enabled on the next CLK edge.

  **Builds through oxibit-ecp5; on the ULX3S-85F with `designs/misc_probe.v` (check the latest oracle run before relying on it).**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  input :gsr, 1
  input :clk, 1

  blackbox :sgsr, "SGSR",
    ports: [
      GSR: :gsr,
      CLK: :clk
    ]
end
