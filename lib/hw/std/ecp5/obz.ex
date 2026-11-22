defmodule Hw.ECP5.OBZ do
  @moduledoc """
  ECP5 tristate output pad buffer: `i` drives the pad, `t` high releases it.
  No read-back; use `Hw.ECP5.BB` when the pad is also read (I2C, MDIO).

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  input :i, 1
  input :t, 1
  output :o, 1

  blackbox :obz, "OBZ", ports: [I: :i, T: :t, O: :o]
end
