defmodule Hw.Nexus.OSCCORE do
  @moduledoc """
  CrossLink-NX internal high-frequency oscillator (`OSC_CORE`): nominally
  450 MHz / (`HF_CLK_DIV` + 1), `HF_CLK_DIV` 0..255. `HF_CLK_DIV: 44` gives
  10 MHz, which divides evenly into milliseconds for `Hw.Std.Tick`.

  Uncalibrated: the frequency is only nominal, so a period built from it is
  exact in clock cycles but approximate in wall-clock time.

  Tie `hfouten` high to run the oscillator.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :HF_CLK_DIV, default: 44

  input :hfouten, 1
  output :hfclkout, 1

  blackbox :osc, "OSC_CORE",
    params: [HF_CLK_DIV: :HF_CLK_DIV],
    ports: [HFOUTEN: :hfouten, HFCLKOUT: :hfclkout]
end
