defmodule Hw.ECP5.DELAYF do
  @moduledoc """
  ECP5 adjustable input/output delay line, in the IOLOGIC beside the pad.

  Starts at `DEL_VALUE` taps (`DEL_MODE: "USER_DEFINED"`). Each `move` pulse
  steps one tap in the direction of `direction` (0 increases the delay);
  `loadn` low reloads `DEL_VALUE`. `cflag` flags that the line is at either
  end of its range. Sits between a pad and an `Hw.ECP5.IDDRX1F`, or between an
  `Hw.ECP5.ODDRX1F` and its pad.

  The ECP5 counterpart of `Hw.Xilinx.IDELAYE2`, without the separate
  reference-clock controller. `Hw.ECP5.DELAYG` is the fixed version.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :DEL_MODE, default: "USER_DEFINED"
  param :DEL_VALUE, default: 0

  input :a, 1
  input :loadn, 1
  input :move, 1
  input :direction, 1
  output :z, 1
  output :cflag, 1

  blackbox :delay, "DELAYF",
    params: [DEL_MODE: :DEL_MODE, DEL_VALUE: :DEL_VALUE],
    ports: [
      A: :a,
      LOADN: :loadn,
      MOVE: :move,
      DIRECTION: :direction,
      Z: :z,
      CFLAG: :cflag
    ]
end
