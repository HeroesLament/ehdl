defmodule Hw.ECP5.OLVDS do
  @moduledoc """
  ECP5 differential output buffer: `z` / `zn` driven from `a`.

  True LVDS output needs a 2.5 V bank. All ULX3S GPIO banks are 3.3 V, so on
  that board this gives a pseudo-differential pair (`IO_TYPE=LVCMOS33D` in the
  `.lpf`), not LVDS.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  input :a, 1
  output :z, 1
  output :zn, 1

  blackbox :olvds, "OLVDS", ports: [A: :a, Z: :z, ZN: :zn]
end
