defmodule Hw.ECP5.USRMCLK do
  @moduledoc """
  ECP5 access to the configuration flash clock pin (MCLK / CCLK).

  The SPI flash clock is a dedicated configuration pin and cannot be named in
  the `.lpf` like a GPIO; after configuration, user logic drives it through
  this primitive. `usrmclki` is the clock, `usrmclkts` high tristates it.
  Needed by anything that reads or writes the boot flash from fabric
  (bitstream update, stored settings).

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  input :usrmclki, 1
  input :usrmclkts, 1

  blackbox :usrmclk, "USRMCLK",
    ports: [USRMCLKI: :usrmclki, USRMCLKTS: :usrmclkts]
end
