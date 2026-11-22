defmodule Hw.ECP5.OSCG do
  @moduledoc """
  ECP5 internal oscillator: roughly 310 MHz / `DIV` (`DIV` 2..128, default
  128, about 2.4 MHz). Uncalibrated and not stable enough to time a UART or
  USB from; useful as a clock that runs before (or without) the board
  oscillator or a PLL, e.g. for a watchdog or a reset sequencer.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :DIV, default: 128

  output :osc, 1

  blackbox :osc, "OSCG",
    params: [DIV: :DIV],
    ports: [OSC: :osc]
end
