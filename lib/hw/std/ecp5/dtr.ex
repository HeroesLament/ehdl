defmodule Hw.ECP5.DTR do
  @moduledoc """
  ECP5 on-die temperature readout. A pulse on `startpulse` starts a
  conversion; `dtrout7..dtrout0` then hold a coarse die-temperature code (the
  ECP5 family datasheet has the code-to-degrees table). Good for a thermal
  telemetry channel, not for measurement.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :DTR_TEMP, default: 25

  input :startpulse, 1
  output :dtrout7, 1
  output :dtrout6, 1
  output :dtrout5, 1
  output :dtrout4, 1
  output :dtrout3, 1
  output :dtrout2, 1
  output :dtrout1, 1
  output :dtrout0, 1

  blackbox :dtr, "DTR",
    params: [DTR_TEMP: :DTR_TEMP],
    ports: [
      STARTPULSE: :startpulse,
      DTROUT7: :dtrout7,
      DTROUT6: :dtrout6,
      DTROUT5: :dtrout5,
      DTROUT4: :dtrout4,
      DTROUT3: :dtrout3,
      DTROUT2: :dtrout2,
      DTROUT1: :dtrout1,
      DTROUT0: :dtrout0
    ]
end
