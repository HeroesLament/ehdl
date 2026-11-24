defmodule Hw.ECP5.ECLKBRIDGECS do
  @moduledoc """
  ECP5 `ECLKBRIDGECS`. Edge-clock bridge: selects CLK0 / CLK1 (SEL) onto the bridge's ECLKSYNCB, which drives the other side's edge clocks.

  **Builds through oxibit-ecp5; on the ULX3S-85F with `designs/misc_probe.v` (check the latest oracle run before relying on it).**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  input :clk0, 1
  input :clk1, 1
  input :sel, 1
  output :ecsout, 1

  blackbox :eclkbridgecs, "ECLKBRIDGECS",
    ports: [
      CLK0: :clk0,
      CLK1: :clk1,
      SEL: :sel,
      ECSOUT: :ecsout
    ]
end
